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

    static func search(root: URL, tree: FileNode?, options: FindInFilesOptions) throws -> FindInFilesSummary {
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw FindInFilesError.emptyQuery }
        let regex = try makeRegex(options: options)

        var matches: [FindInFilesMatch] = []
        var searchedFiles = 0
        var skippedFiles = 0

        for node in FileNode.flatten(tree) where !node.isDirectory {
            guard matches.count < maxMatches else {
                return FindInFilesSummary(
                    matches: matches,
                    searchedFiles: searchedFiles,
                    skippedFiles: skippedFiles,
                    hitLimit: true
                )
            }

            let url = SecurityScopedResourceAccess.prepare(
                node.url,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
                shouldRemember: false
            )
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

            let text = TextFileIO.decode(data: data).text
            searchedFiles += 1
            appendMatches(
                in: text,
                url: url,
                root: root,
                regex: regex,
                remainingLimit: maxMatches - matches.count,
                to: &matches
            )
        }

        return FindInFilesSummary(
            matches: matches,
            searchedFiles: searchedFiles,
            skippedFiles: skippedFiles,
            hitLimit: matches.count >= maxMatches
        )
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

        for node in FileNode.flatten(tree) where !node.isDirectory {
            let url = SecurityScopedResourceAccess.prepare(
                node.url,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
                shouldRemember: false
            )
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
            pattern = #"\b"# + pattern + #"\b"#
        }
        var regexOptions: NSRegularExpression.Options = []
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

    private static func appendMatches(
        in text: String,
        url: URL,
        root: URL,
        regex: NSRegularExpression,
        remainingLimit: Int,
        to matches: inout [FindInFilesMatch]
    ) {
        guard remainingLimit > 0 else { return }

        let ns = text as NSString
        let relativePath = url.path(relativeTo: root)
        var lineStart = 0
        var lineNumber = 1

        while lineStart < ns.length, matches.count < remainingLimit {
            let paragraphRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            var contentRange = paragraphRange
            while contentRange.length > 0 {
                let last = ns.character(at: NSMaxRange(contentRange) - 1)
                if last == 10 || last == 13 {
                    contentRange.length -= 1
                } else {
                    break
                }
            }

            let line = ns.substring(with: contentRange)
            let lineMatches = regex.matches(
                in: line,
                options: [],
                range: NSRange(location: 0, length: (line as NSString).length)
            )

            for match in lineMatches where match.range.location != NSNotFound {
                matches.append(
                    FindInFilesMatch(
                        url: url,
                        relativePath: relativePath,
                        lineNumber: lineNumber,
                        column: match.range.location + 1,
                        preview: previewLine(line)
                    )
                )
                if matches.count >= remainingLimit {
                    break
                }
            }

            let next = NSMaxRange(paragraphRange)
            if next <= lineStart { break }
            lineStart = next
            lineNumber += 1
        }
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
