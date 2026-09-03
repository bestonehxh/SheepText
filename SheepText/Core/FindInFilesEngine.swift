//
//  FindInFilesEngine.swift
//  Workspace-wide text search.
//

import Foundation

nonisolated struct FindInFilesOptions: Sendable {
    var query: String
    var caseSensitive: Bool
    var wholeWord: Bool
    var useRegex: Bool
}

nonisolated struct FindInFilesMatch: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let relativePath: String
    let lineNumber: Int
    let column: Int
    let preview: String
}

nonisolated struct FindInFilesSummary: Sendable {
    var matches: [FindInFilesMatch]
    var searchedFiles: Int
    var skippedFiles: Int
    var hitLimit: Bool
}

nonisolated struct ReplaceInFilesSummary: Sendable {
    var changedURLs: Set<URL>
    var replacementCount: Int
    var searchedFiles: Int
    var skippedFiles: Int
    var backupDirectory: URL?
}

nonisolated enum FindInFilesError: LocalizedError {
    case emptyQuery
    case invalidPattern

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Enter text to search."
        case .invalidPattern:
            return "Invalid regular expression."
        }
    }
}

nonisolated enum FindInFilesEngine {
    private static let maxFileSize = 2_000_000
    private static let maxMatches = 1_000

    private static let skippedExtensions: Set<String> = [
        "app", "bin", "bmp", "class", "dmg", "dylib", "exe", "gif", "heic",
        "icns", "ico", "jar", "jpeg", "jpg", "mov", "mp3", "mp4", "o",
        "pdf", "png", "so", "sqlite", "tiff", "webp", "xcuserstate", "zip"
    ]

    /// - Parameter isCancelled: consulted once per file and once per match, so a
    ///   superseded search stops reading files instead of running to completion
    ///   behind the one the user is waiting for.
    static func search(
        root: URL,
        tree: FileNode?,
        options: FindInFilesOptions,
        isCancelled: () -> Bool = { false }
    ) throws -> FindInFilesSummary {
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw FindInFilesError.emptyQuery }
        let regex = try makeRegex(options: options)

        var matches: [FindInFilesMatch] = []
        var searchedFiles = 0
        var skippedFiles = 0

        // One scope resolve for the whole search. It used to happen per file —
        // a UserDefaults bookmark-dictionary copy and a
        // URL(resolvingBookmarkData:) for every file in the workspace — even
        // though every file in the tree lives under this root's scope.
        _ = SecurityScopedResourceAccess.prepare(
            root,
            bookmarkKey: SecurityScopedResourceAccess.workspaceBookmarksKey,
            shouldRemember: false
        )

        for node in FileNode.flatten(tree) where !node.isDirectory {
            // `maxMatches` is the absolute cap. The caller used to pass
            // `maxMatches - matches.count` as a "remaining" budget and
            // `appendMatches` compared the *total* against it, so the loop
            // stopped at count >= limit - count — an effective cap of 500 that
            // never tripped this guard and reported hitLimit false.
            guard matches.count < maxMatches, !isCancelled() else {
                return FindInFilesSummary(
                    matches: matches,
                    searchedFiles: searchedFiles,
                    skippedFiles: skippedFiles,
                    hitLimit: matches.count >= maxMatches
                )
            }

            let url = node.url
            guard shouldSearch(url) else {
                skippedFiles += 1
                continue
            }

            guard let data = try? Data(contentsOf: url),
                  data.count <= maxFileSize,
                  !looksBinary(data)
            else {
                skippedFiles += 1
                continue
            }

            searchedFiles += 1
            appendMatches(
                in: searchText(from: data),
                url: url,
                root: root,
                regex: regex,
                limit: maxMatches,
                to: &matches,
                isCancelled: isCancelled
            )
        }

        return FindInFilesSummary(
            matches: matches,
            searchedFiles: searchedFiles,
            skippedFiles: skippedFiles,
            hitLimit: matches.count >= maxMatches
        )
    }

    /// Search only needs the characters, not the encoding, and the overwhelming
    /// majority of a source tree is BOM-less UTF-8 — which the full detection
    /// chain reaches only after building and discarding a whole decode.
    private static func searchText(from data: Data) -> String {
        if !data.starts(with: [0xEF, 0xBB, 0xBF]),
           let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return TextFileIO.decode(data: data).text
    }

    static func replaceAll(
        root: URL,
        tree: FileNode?,
        options: FindInFilesOptions,
        replacement: String
    ) throws -> ReplaceInFilesSummary {
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw FindInFilesError.emptyQuery }
        let regex = try makeRegex(options: options)
        let replacementTemplate = options.useRegex
            ? replacement
            : NSRegularExpression.escapedTemplate(for: replacement)

        var changedURLs = Set<URL>()
        var replacementCount = 0
        var searchedFiles = 0
        var skippedFiles = 0
        var backupDirectory: URL?

        // One scope resolve for the whole pass; see `search`.
        _ = SecurityScopedResourceAccess.prepare(
            root,
            bookmarkKey: SecurityScopedResourceAccess.workspaceBookmarksKey,
            shouldRemember: false
        )

        for node in FileNode.flatten(tree) where !node.isDirectory {
            let url = node.url
            guard shouldSearch(url) else {
                skippedFiles += 1
                continue
            }

            guard let data = try? Data(contentsOf: url),
                  data.count <= maxFileSize,
                  !looksBinary(data)
            else {
                skippedFiles += 1
                continue
            }

            let decoded = TextFileIO.decode(data: data)
            let text = decoded.text
            searchedFiles += 1

            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            let count = regex.numberOfMatches(in: text, options: [], range: fullRange)
            guard count > 0 else { continue }

            let replaced = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: fullRange,
                withTemplate: replacementTemplate
            )

            let backupRoot: URL
            if let existingBackupDirectory = backupDirectory {
                backupRoot = existingBackupDirectory
            } else {
                backupRoot = try makeBackupDirectory()
                backupDirectory = backupRoot
            }
            try backupOriginalFile(data: data, url: url, root: root, backupRoot: backupRoot)

            try TextFileIO.write(
                text: replaced,
                to: url,
                encoding: decoded.encoding,
                writeBOM: decoded.hadBOM
            )

            changedURLs.insert(url)
            replacementCount += count
        }

        return ReplaceInFilesSummary(
            changedURLs: changedURLs,
            replacementCount: replacementCount,
            searchedFiles: searchedFiles,
            skippedFiles: skippedFiles,
            backupDirectory: backupDirectory
        )
    }

    private static func makeBackupDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let parent = base
            .appendingPathComponent("SheepText", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("ReplaceInFiles", isDirectory: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: Date())

        var candidate = parent.appendingPathComponent(stamp, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(stamp)-\(counter)", isDirectory: true)
            counter += 1
        }

        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private static func backupOriginalFile(data: Data, url: URL, root: URL, backupRoot: URL) throws {
        let relativePath = url.path(relativeTo: root)
        let backupURL = backupRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: backupURL, options: .atomic)
    }

    private static func makeRegex(options: FindInFilesOptions) throws -> NSRegularExpression {
        var pattern = options.useRegex
            ? options.query
            : NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord {
            // Non-capturing group, because alternation binds looser than
            // concatenation: `\bfoo|bar\b` is "\bfoo" OR "bar\b", not what the
            // user asked for.
            pattern = #"\b(?:"# + pattern + #")\b"#
        }
        // The scan runs over the whole file in one pass now (it used to feed the
        // regex one line at a time), so ^ and $ have to be told to keep meaning
        // "start/end of line".
        var regexOptions: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive {
            regexOptions.insert(.caseInsensitive)
        }
        do {
            return try NSRegularExpression(pattern: pattern, options: regexOptions)
        } catch {
            throw FindInFilesError.invalidPattern
        }
    }

    private static func shouldSearch(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if skippedExtensions.contains(ext) {
            return false
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == false {
            return false
        }
        if let fileSize = values?.fileSize, fileSize > maxFileSize {
            return false
        }
        return true
    }

    private static func looksBinary(_ data: Data) -> Bool {
        TextFileIO.looksBinary(data)
    }

    /// One regex pass over the whole file.
    ///
    /// This used to walk the file line by line: `lineRange`, `substring` (a
    /// fresh String, re-bridged to NSString for its length) and a separate
    /// `regex.matches` call — per line, for every file, whether or not the line
    /// contained anything. Now the regex runs once over the text and the line
    /// number comes from a table of line starts, which is only built when a file
    /// actually matches.
    private static func appendMatches(
        in text: String,
        url: URL,
        root: URL,
        regex: NSRegularExpression,
        limit: Int,
        to matches: inout [FindInFilesMatch],
        isCancelled: () -> Bool
    ) {
        guard matches.count < limit else { return }

        let ns = text as NSString
        guard ns.length > 0 else { return }
        let relativePath = url.path(relativeTo: root)

        var lineStarts: [Int]?
        var previewCache: (line: Int, text: String)?

        regex.enumerateMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ) { result, _, stop in
            guard let range = result?.range, range.location != NSNotFound else { return }
            if isCancelled() {
                stop.pointee = true
                return
            }

            let starts = lineStarts ?? Self.lineStartOffsets(in: ns)
            lineStarts = starts

            let lineIndex = Self.lineIndex(for: range.location, in: starts)
            let preview: String
            if let cached = previewCache, cached.line == lineIndex {
                preview = cached.text
            } else {
                preview = previewLine(Self.lineContent(at: lineIndex, starts: starts, ns: ns))
                previewCache = (lineIndex, preview)
            }

            matches.append(
                FindInFilesMatch(
                    url: url,
                    relativePath: relativePath,
                    lineNumber: lineIndex + 1,
                    column: range.location - starts[lineIndex] + 1,
                    preview: preview
                )
            )
            if matches.count >= limit {
                stop.pointee = true
            }
        }
    }

    /// UTF-16 offset of the first character of every line.
    private static func lineStartOffsets(in ns: NSString) -> [Int] {
        var starts: [Int] = [0]
        var buffer = CFStringInlineBuffer()
        let length = ns.length
        CFStringInitInlineBuffer(ns as CFString, &buffer, CFRange(location: 0, length: length))
        for index in 0..<length where CFStringGetCharacterFromInlineBuffer(&buffer, index) == 10 {
            starts.append(index + 1)
        }
        return starts
    }

    private static func lineIndex(for location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func lineContent(at lineIndex: Int, starts: [Int], ns: NSString) -> String {
        let start = starts[lineIndex]
        var end = lineIndex + 1 < starts.count ? starts[lineIndex + 1] : ns.length
        while end > start {
            let last = ns.character(at: end - 1)
            if last == 10 || last == 13 { end -= 1 } else { break }
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func previewLine(_ line: String) -> String {
        let normalized = line
            .replacingOccurrences(of: "\t", with: "    ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= 220 {
            return normalized
        }
        return String(normalized.prefix(220)) + "..."
    }
}

private extension URL {
    nonisolated func path(relativeTo base: URL) -> String {
        guard path.hasPrefix(base.path) else { return path }
        let trimmed = String(path.dropFirst(base.path.count))
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    }
}
