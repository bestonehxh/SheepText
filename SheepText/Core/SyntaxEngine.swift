//
//  SyntaxEngine.swift
//  Syntax highlighting powered by Tree-sitter grammars for all supported languages.
//
//  Architecture:
//  - One shared serial queue keeps all parse + highlight work off the main thread.
//  - Parser instances are cached per language so they are reused across calls
//    instead of being allocated and configured on every keystroke.
//  - LanguageConfiguration (grammar + queries) is also cached per language.
//  - Colors use sRGB so they render identically regardless of display profile.
//  - Capture names are resolved via component-based matching that handles the full
//    tree-sitter hierarchy including legacy nvim-treesitter names (text.*) and the
//    newer markup.* hierarchy.
//  - The "default_" capture category emits NO foreground-color attribute so tokens
//    inherit the editor's base foreground color exactly.
//  - Markdown loads only highlights.scm (not injections.scm) to avoid a known
//    LanguageConfiguration failure path on embedded injection predicates.
//

import Foundation
import AppKit
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterBestTextLog
import TreeSitterC
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterDockerfile
import TreeSitterElixir
import TreeSitterGo
import TreeSitterHaskell
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterScala
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML
import TreeSitterSql
import TreeSitterDiff

// MARK: - Public API

/// NSAttributedString is immutable here but AppKit does not declare it Sendable.
/// This private hand-off wrapper is the only unchecked boundary exposed by the
/// Tree-sitter worker queue.
nonisolated private struct SyntaxHighlightResult: @unchecked Sendable {
    let value: NSAttributedString?
    /// nil means the whole document must be repainted. An empty array means
    /// the text's syntax attributes are already correct after AppKit shifted
    /// them with the edit.
    let changedRanges: [NSRange]?
}

/// Parser/configuration instances never escape the private serial queue.
nonisolated final class SyntaxEngine: @unchecked Sendable {

    static let shared = SyntaxEngine()

    private let queue = DispatchQueue(label: "sheeptext.syntax", qos: .userInitiated)
    private var configurations: [String: LanguageConfiguration] = [:]
    private var parsers: [String: Parser] = [:]

    /// A (UTF-16 index, tree-sitter Point) pair that is valid for a specific
    /// text. Carrying these forward lets the next edit compute its Points by
    /// walking from the nearest anchor instead of from the start of the file.
    fileprivate struct PointAnchor {
        let index: Int
        let point: Point
    }

    private struct ParseSession {
        let language: String
        let isDark: Bool
        let text: String
        let tree: Tree?
        /// The previous pass's finished highlight. Reused as the base for the
        /// next incremental pass so a keystroke does not rebuild the attributed
        /// string for the whole document.
        let attributed: NSAttributedString?
        let anchors: [PointAnchor]
    }

    /// A session pins the document's full text, a copy of its syntax tree and
    /// its last attributed string. Closing a tab calls `discardSession`; this
    /// cap is the backstop for anything that does not (compare panes, snapshots,
    /// documents replaced in place).
    private static let sessionLimit = 8
    private var sessions: [UUID: ParseSession] = [:]
    private var sessionOrder: [UUID] = []

    init() {}

    /// Release the incremental-parse state for a document.
    ///
    /// Sessions used to be write-only: every highlight pass inserted one and
    /// nothing ever removed it, so every document opened in the process stayed
    /// resident — text, tree and attributed string — until the app quit.
    func discardSession(for documentID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions.removeValue(forKey: documentID)
            self.sessionOrder.removeAll { $0 == documentID }
        }
    }

    private func storeSession(_ session: ParseSession, for documentID: UUID) {
        sessions[documentID] = session
        sessionOrder.removeAll { $0 == documentID }
        sessionOrder.append(documentID)
        while sessionOrder.count > Self.sessionLimit {
            let evicted = sessionOrder.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
    }

    static func supportsHighlighting(_ language: String) -> Bool {
        guard let mapped = mapLanguage(language) else { return false }
        // Regex-based languages don't need a Tree-sitter grammar bundle.
        if mapped == "cisco_ios" || mapped == "aruba_cx" { return true }
        // Tree-sitter languages require the grammar spec to exist.
        return grammarSpecs[mapped] != nil
    }

    @MainActor
    func highlight(
        text: String,
        language: String,
        isDark: Bool,
        documentID: UUID,
        completion: @escaping @MainActor @Sendable (
            _ result: NSAttributedString?,
            _ changedRanges: [NSRange]?,
            _ background: NSColor
        ) -> Void
    ) {
        // No generation filter here on purpose. There used to be one counter for
        // the whole process, so a request from ANY editor cancelled the pending
        // completion of every other one — with two windows open, one of them
        // simply never got its highlights. Staleness is the caller's business and
        // every caller already checks: EditorView.Coordinator carries its own
        // per-coordinator `highlightGeneration` and drops late results.
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.highlightedString(
                for: text,
                language: language,
                isDark: isDark,
                documentID: documentID
            )
            DispatchQueue.main.async {
                completion(result.value, result.changedRanges, .bestTextEditorBackground)
            }
        }
    }

    @MainActor
    func highlightSnapshot(
        text: String,
        language: String,
        isDark: Bool,
        completion: @escaping @MainActor @Sendable (_ result: NSAttributedString?, _ background: NSColor) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = SyntaxHighlightResult(
                value: self.highlightedString(for: text, language: language, isDark: isDark).value,
                changedRanges: nil
            )
            DispatchQueue.main.async {
                completion(result.value, .bestTextEditorBackground)
            }
        }
    }

    @MainActor
    func highlightImmediately(
        text: String,
        language: String,
        isDark: Bool,
        documentID: UUID? = nil
    ) -> NSAttributedString? {
        queue.sync {
            highlightedString(
                for: text,
                language: language,
                isDark: isDark,
                documentID: documentID
            ).value
        }
    }

    func setTheme(_: String) {}

    // MARK: - Core

    private func highlightedString(
        for text: String,
        language: String,
        isDark: Bool,
        documentID: UUID? = nil
    ) -> SyntaxHighlightResult {
        guard let mapped = Self.mapLanguage(language) else {
            return SyntaxHighlightResult(value: nil, changedRanges: nil)
        }

        let priorSession = documentID.flatMap { sessions[$0] }
        let textEdit = priorSession.flatMap { session -> IncrementalTextEdit? in
            guard session.language == mapped, session.isDark == isDark, session.text != text
            else { return nil }
            return Self.incrementalEdit(from: session.text, to: text, anchors: session.anchors)
        }

        if mapped == "cisco_ios" || mapped == "aruba_cx" {
            let value = mapped == "cisco_ios"
                ? Self.ciscoIosHighlight(text: text, isDark: isDark)
                : Self.arubaCxHighlight(text: text, isDark: isDark)
            let ranges = textEdit.map { Self.paragraphRanges([$0.newRange], in: text) }
            if let documentID {
                storeSession(
                    ParseSession(
                        language: mapped,
                        isDark: isDark,
                        text: text,
                        tree: nil,
                        attributed: nil,
                        anchors: textEdit?.anchors ?? []
                    ),
                    for: documentID
                )
            }
            return SyntaxHighlightResult(value: value, changedRanges: ranges)
        }

        guard let config = configuration(for: mapped),
              let parser = cachedParser(for: mapped, config: config)
        else { return SyntaxHighlightResult(value: nil, changedRanges: nil) }

        let tree: MutableTree
        var changedRanges: [NSRange]?
        if let edit = textEdit,
           let oldTree = priorSession?.tree,
           let editedTree = oldTree.edit(edit.inputEdit),
           let newTree = parser.parse(tree: editedTree, string: text) {
            tree = newTree
            let syntaxRanges = editedTree.changedRanges(from: newTree).map { $0.bytes.range }
            changedRanges = Self.paragraphRanges(syntaxRanges + [edit.newRange], in: text)
        } else if let parsed = parser.parse(text) {
            tree = parsed
            changedRanges = nil
        } else {
            return SyntaxHighlightResult(value: nil, changedRanges: nil)
        }

        guard let query = config.queries[.highlights] else {
            return SyntaxHighlightResult(value: nil, changedRanges: nil)
        }

        let nsText = text as NSString
        let sourceLength = nsText.length
        let fullRange = NSRange(location: 0, length: sourceLength)
        let context = Predicate.Context(string: text)
        let injectionQuery = config.queries[.injections]

        // Reusing the previous pass's attributed string requires that every
        // attribute in the document can be re-derived from the ranges the edit
        // touched. That holds for the highlights query and for injections, both
        // of which can be restricted to a byte range. It does NOT hold for
        // Markdown: opening a ``` fence retints everything after it, and that
        // pass is a document-wide regex, so Markdown keeps the full rebuild.
        let canReuseAttributes = mapped != "markdown"

        var reusedOutput: NSMutableAttributedString?
        var queryRanges: [NSRange]?

        if canReuseAttributes,
           let edit = textEdit,
           let ranges = changedRanges,
           let prior = priorSession?.attributed,
           let priorText = priorSession?.text,
           prior.length == (priorText as NSString).length,
           NSMaxRange(edit.oldRange) <= prior.length {
            // Splice the edit into last pass's attributes, then clear and
            // recompute only the paragraphs tree-sitter says changed. This is
            // what makes the incremental parse actually pay off: the parse was
            // never the expensive part, rebuilding a document-sized attributed
            // string and re-running the query over the whole tree was.
            let reused = NSMutableAttributedString(attributedString: prior)
            reused.replaceCharacters(in: edit.oldRange, with: nsText.substring(with: edit.newRange))
            if reused.length == sourceLength {
                for range in ranges where NSMaxRange(range) <= sourceLength {
                    reused.setAttributes(nil, range: range)
                }
                reusedOutput = reused
                queryRanges = ranges
            }
        }

        let output = reusedOutput ?? NSMutableAttributedString(string: text)

        // Primary language highlights
        for range in queryRanges ?? [fullRange] {
            Self.applyHighlights(
                query: query,
                tree: tree,
                context: context,
                restrictedTo: queryRanges == nil ? nil : range,
                isDark: isDark,
                fullRange: fullRange,
                into: output
            )
        }

        // Markdown fenced code blocks: injections.scm can't be loaded for markdown
        // (LanguageConfiguration fails on its predicate syntax), so we use a regex
        // to locate ```lang\n...\n``` regions and highlight them directly.
        if mapped == "markdown" {
            highlightMarkdownCodeBlocks(
                in: text, nsText: nsText, fullRange: fullRange,
                output: output, isDark: isDark
            )
        }

        // Injected language highlights — same mechanism Zed uses.
        // injections.scm entries like:
        //   ((style_element (raw_text) @injection.content) (#set! injection.language "css"))
        // produce NamedRange where .name = "css" and .range = the raw_text NSRange.
        if let injectionQuery {
            for range in queryRanges ?? [fullRange] {
                applyInjections(
                    query: injectionQuery,
                    tree: tree,
                    context: context,
                    restrictedTo: queryRanges == nil ? nil : range,
                    nsText: nsText,
                    fullRange: fullRange,
                    isDark: isDark,
                    into: output
                )
            }
        }

        let finished = output.copy() as? NSAttributedString
            ?? NSAttributedString(attributedString: output)

        if let documentID, let savedTree = tree.copy() {
            storeSession(
                ParseSession(
                    language: mapped,
                    isDark: isDark,
                    text: text,
                    tree: savedTree,
                    attributed: canReuseAttributes ? finished : nil,
                    anchors: textEdit?.anchors ?? []
                ),
                for: documentID
            )
        }

        return SyntaxHighlightResult(value: finished, changedRanges: changedRanges)
    }

    /// Run the highlights query and paint the captures.
    ///
    /// `restrictedTo` limits the tree walk to a byte range. `Query.execute`
    /// already called `ts_query_cursor_exec`, but that call only seeds the
    /// cursor — matching happens lazily in `next()` — so the range has to be set
    /// and `exec` re-run, otherwise the restriction is silently ignored.
    private static func applyHighlights(
        query: Query,
        tree: MutableTree,
        context: SwiftTreeSitter.Predicate.Context,
        restrictedTo range: NSRange?,
        isDark: Bool,
        fullRange: NSRange,
        into output: NSMutableAttributedString
    ) {
        guard let root = tree.rootNode else { return }
        let cursor = query.execute(node: root, in: tree)
        if let range, range.length > 0 {
            cursor.setRange(range)
            cursor.execute(query: query, node: root)
        }
        for highlight in cursor.resolve(with: context).highlights() {
            let hlRange = NSIntersectionRange(highlight.range, fullRange)
            guard hlRange.length > 0 else { continue }
            let attrs = attributes(for: highlight.name, isDark: isDark)
            guard !attrs.isEmpty else { continue }
            output.addAttributes(attrs, range: hlRange)
        }
    }

    /// Injected language highlights — same mechanism Zed uses.
    /// injections.scm entries like:
    ///   ((style_element (raw_text) @injection.content) (#set! injection.language "css"))
    /// produce NamedRange where .name = "css" and .range = the raw_text NSRange.
    ///
    /// `restrictedTo` limits which injection sites are revisited. An injection
    /// whose content changed shows up in the edit's changed ranges, so on an
    /// incremental pass the untouched ones keep the attributes they already have.
    private func applyInjections(
        query injectionQuery: Query,
        tree: MutableTree,
        context: SwiftTreeSitter.Predicate.Context,
        restrictedTo range: NSRange?,
        nsText: NSString,
        fullRange: NSRange,
        isDark: Bool,
        into output: NSMutableAttributedString
    ) {
        guard let root = tree.rootNode else { return }
        let cursor = injectionQuery.execute(node: root, in: tree)
        if let range, range.length > 0 {
            cursor.setRange(range)
            cursor.execute(query: injectionQuery, node: root)
        }

        for injection in cursor.resolve(with: context).injections() {
            let injRange = NSIntersectionRange(injection.range, fullRange)
            guard injRange.length > 0 else { continue }

            guard let injMapped = Self.mapLanguage(injection.name),
                  let injConfig = configuration(for: injMapped),
                  let injParser = cachedParser(for: injMapped, config: injConfig)
            else { continue }

            let injContent = nsText.substring(with: injRange)
            guard let injTree = injParser.parse(injContent),
                  let injQuery = injConfig.queries[.highlights]
            else { continue }

            let injContext = SwiftTreeSitter.Predicate.Context(string: injContent)
            let injFullRange = NSRange(location: 0, length: (injContent as NSString).length)

            for highlight in injQuery.execute(in: injTree).resolve(with: injContext).highlights() {
                var hlRange = NSIntersectionRange(highlight.range, injFullRange)
                guard hlRange.length > 0 else { continue }
                hlRange.location += injRange.location
                hlRange = NSIntersectionRange(hlRange, fullRange)
                guard hlRange.length > 0 else { continue }
                let attrs = Self.attributes(for: highlight.name, isDark: isDark)
                guard !attrs.isEmpty else { continue }
                output.addAttributes(attrs, range: hlRange)
            }
        }
    }

    private struct IncrementalTextEdit {
        let inputEdit: InputEdit
        /// The replaced span, in the OLD text.
        let oldRange: NSRange
        /// The replacement span, in the NEW text.
        let newRange: NSRange
        /// Anchors valid in the NEW text, to seed the next edit's Point maths.
        let anchors: [PointAnchor]
    }

    /// Collapses all edits that happened during the debounce window into one
    /// replacement. Tree-sitter can still reuse the unchanged prefix/suffix,
    /// including for paste, multi-cursor edits, undo and replace-all.
    ///
    /// Every scan here reads through a `CFStringInlineBuffer`. It used to call
    /// `NSString.character(at:)`, which is an objc_msgSend per character — the
    /// affix scan alone crosses the whole document, so a keystroke at the end of
    /// a 500k-character file cost hundreds of thousands of message sends before
    /// the parser had done any work.
    private static func incrementalEdit(
        from oldText: String,
        to newText: String,
        anchors priorAnchors: [PointAnchor]
    ) -> IncrementalTextEdit {
        let old = oldText as NSString
        let new = newText as NSString
        let (prefix, suffix) = commonAffixLengths(old: old, new: new)

        let oldEnd = old.length - suffix
        let newEnd = new.length - suffix
        let startPoint = point(in: old, at: prefix, anchors: priorAnchors)
        let startAnchor = PointAnchor(index: prefix, point: startPoint)
        let oldEndPoint = point(in: old, at: oldEnd, anchors: priorAnchors + [startAnchor])
        // `prefix` is common to both strings, so the start anchor is valid in
        // the new text too.
        let newEndPoint = point(in: new, at: newEnd, anchors: [startAnchor])
        let inputEdit = InputEdit(
            startByte: prefix * 2,
            oldEndByte: oldEnd * 2,
            newEndByte: newEnd * 2,
            startPoint: startPoint,
            oldEndPoint: oldEndPoint,
            newEndPoint: newEndPoint
        )
        return IncrementalTextEdit(
            inputEdit: inputEdit,
            oldRange: NSRange(location: prefix, length: oldEnd - prefix),
            newRange: NSRange(location: prefix, length: newEnd - prefix),
            anchors: [startAnchor, PointAnchor(index: newEnd, point: newEndPoint)]
        )
    }

    /// Length of the common prefix and suffix of two strings, in UTF-16 units,
    /// never splitting a surrogate pair and never letting the two overlap.
    private static func commonAffixLengths(old: NSString, new: NSString) -> (prefix: Int, suffix: Int) {
        let oldLength = old.length
        let newLength = new.length
        var oldBuffer = CFStringInlineBuffer()
        var newBuffer = CFStringInlineBuffer()
        CFStringInitInlineBuffer(old as CFString, &oldBuffer, CFRangeMake(0, oldLength))
        CFStringInitInlineBuffer(new as CFString, &newBuffer, CFRangeMake(0, newLength))
        defer {
            withExtendedLifetime(old) {}
            withExtendedLifetime(new) {}
        }

        let commonLimit = min(oldLength, newLength)
        var prefix = 0
        while prefix < commonLimit,
              CFStringGetCharacterFromInlineBuffer(&oldBuffer, prefix)
                == CFStringGetCharacterFromInlineBuffer(&newBuffer, prefix) {
            prefix += 1
        }

        // Never place a Tree-sitter edit boundary between a UTF-16 surrogate pair.
        if prefix > 0, prefix < commonLimit,
           CFStringIsSurrogateHighCharacter(
               CFStringGetCharacterFromInlineBuffer(&oldBuffer, prefix - 1)
           ) {
            prefix -= 1
        }

        var suffix = 0
        while suffix < oldLength - prefix,
              suffix < newLength - prefix,
              CFStringGetCharacterFromInlineBuffer(&oldBuffer, oldLength - suffix - 1)
                == CFStringGetCharacterFromInlineBuffer(&newBuffer, newLength - suffix - 1) {
            suffix += 1
        }
        if suffix > 0,
           (oldLength - suffix) < oldLength,
           CFStringIsSurrogateLowCharacter(
               CFStringGetCharacterFromInlineBuffer(&oldBuffer, oldLength - suffix)
           ) {
            suffix -= 1
        }

        return (prefix, suffix)
    }

    /// Row/column of a UTF-16 index, walked forward from the nearest usable
    /// anchor rather than from the start of the document.
    private static func point(in text: NSString, at index: Int, anchors: [PointAnchor]) -> Point {
        var best = PointAnchor(index: 0, point: .zero)
        for anchor in anchors where anchor.index <= index && anchor.index > best.index {
            best = anchor
        }
        guard index > best.index else { return best.point }

        let length = text.length
        var buffer = CFStringInlineBuffer()
        CFStringInitInlineBuffer(text as CFString, &buffer, CFRangeMake(0, length))
        defer { withExtendedLifetime(text) {} }

        var row = Int(best.point.row)
        var columnBytes = Int(best.point.column)
        for cursor in best.index..<min(index, length) {
            if CFStringGetCharacterFromInlineBuffer(&buffer, cursor) == 0x0A {
                row += 1
                columnBytes = 0
            } else {
                columnBytes += 2
            }
        }
        return Point(row: row, column: columnBytes)
    }

    /// Tree changed ranges can be token-sized. Repainting whole paragraphs also
    /// clears stale attributes around token boundaries and covers whitespace-only
    /// edits, while remaining much smaller than repainting the document.
    private static func paragraphRanges(_ ranges: [NSRange], in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        let expanded = ranges.compactMap { range -> NSRange? in
            guard range.location != NSNotFound else { return nil }
            let location = min(max(0, range.location), ns.length)
            let maxLength = ns.length - location
            let safe = NSRange(location: location, length: min(max(0, range.length), maxLength))
            return ns.lineRange(for: safe)
        }.sorted { $0.location < $1.location }

        var merged: [NSRange] = []
        for range in expanded where range.length > 0 {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Compiled once: this used to be rebuilt on every Markdown highlight pass.
    private static let markdownFenceRegex = try? NSRegularExpression(
        pattern: "^```(\\w[-\\w]*)[ \\t]*\\r?\\n([\\s\\S]*?)^```[ \\t]*$",
        options: .anchorsMatchLines
    )

    // Highlight fenced code blocks inside a Markdown document.
    // Regex finds ``` lang \n content ``` and runs the matching language parser
    // on the content region, then offsets the resulting ranges back into the
    // full document so attributes land on the right characters.
    private func highlightMarkdownCodeBlocks(
        in text: String,
        nsText: NSString,
        fullRange: NSRange,
        output: NSMutableAttributedString,
        isDark: Bool
    ) {
        guard let regex = Self.markdownFenceRegex else { return }

        for match in regex.matches(in: text, range: fullRange) {
            let langRange    = match.range(at: 1)
            let contentRange = match.range(at: 2)
            guard langRange.location != NSNotFound, contentRange.location != NSNotFound,
                  contentRange.length > 0 else { continue }

            let lang    = nsText.substring(with: langRange).lowercased()
            let content = nsText.substring(with: contentRange)

            guard let mapped     = Self.mapLanguage(lang),
                  let injConfig  = configuration(for: mapped),
                  let injParser  = cachedParser(for: mapped, config: injConfig),
                  let injTree    = injParser.parse(content),
                  let injQuery   = injConfig.queries[.highlights]
            else { continue }

            let injContext   = Predicate.Context(string: content)
            let injFullRange = NSRange(location: 0, length: (content as NSString).length)

            for highlight in injQuery.execute(in: injTree).resolve(with: injContext).highlights() {
                var hlRange = NSIntersectionRange(highlight.range, injFullRange)
                guard hlRange.length > 0 else { continue }
                hlRange.location += contentRange.location
                hlRange = NSIntersectionRange(hlRange, fullRange)
                guard hlRange.length > 0 else { continue }
                let attrs = Self.attributes(for: highlight.name, isDark: isDark)
                guard !attrs.isEmpty else { continue }
                output.addAttributes(attrs, range: hlRange)
            }
        }
    }

    // MARK: - Parser cache

    private func cachedParser(for language: String, config: LanguageConfiguration) -> Parser? {
        if let existing = parsers[language] { return existing }
        let p = Parser()
        guard (try? p.setLanguage(config.language)) != nil else { return nil }
        parsers[language] = p
        return p
    }

    // MARK: - Configuration cache

    private func configuration(for language: String) -> LanguageConfiguration? {
        if let existing = configurations[language] { return existing }

        guard let spec = Self.grammarSpecs[language],
              let packageQueriesURL = Self.queriesURL(forBundleNamed: spec.bundleName),
              let tsLanguage = spec.language()
        else { return nil }

        let candidateQueryURLs = Self.sheeptextQueryCandidates(for: language) + [packageQueriesURL]

        for candidateURL in candidateQueryURLs {
            let loadURL = language == "markdown"
                ? (Self.highlightsOnlyDirectory(from: candidateURL) ?? candidateURL)
                : candidateURL

            if let config = try? LanguageConfiguration(tsLanguage, name: spec.name, queriesURL: loadURL) {
                configurations[language] = config
                return config
            }
        }

        return nil
    }

    // Looks for SheepText per-language query overrides before using bundled grammar queries.
    // Runtime path:
    // ~/Library/Application Support/SheepText/SheepTextTreeSitterQueries/<language>/highlights.scm
    // App resource path:
    // SheepTextTreeSitterQueries/<language>/highlights.scm
    private static func sheeptextQueryCandidates(for language: String) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let runtimeURL = appSupport
                .appendingPathComponent("SheepText", isDirectory: true)
                .appendingPathComponent("SheepTextTreeSitterQueries", isDirectory: true)
                .appendingPathComponent(language, isDirectory: true)
            if fm.fileExists(atPath: runtimeURL.appendingPathComponent("highlights.scm").path) {
                urls.append(runtimeURL)
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundledURL = resourceURL
                .appendingPathComponent("SheepTextTreeSitterQueries", isDirectory: true)
                .appendingPathComponent(language, isDirectory: true)
            if fm.fileExists(atPath: bundledURL.appendingPathComponent("highlights.scm").path) {
                urls.append(bundledURL)
            }
        }

        return urls
    }

    // Copies only highlights.scm into a temp directory so LanguageConfiguration
    // never sees injections.scm or locals.scm for markdown.
    private static func highlightsOnlyDirectory(from queriesURL: URL) -> URL? {
        let fm = FileManager.default
        let src = queriesURL.appendingPathComponent("highlights.scm")
        guard fm.fileExists(atPath: src.path) else { return nil }

        let dir = fm.temporaryDirectory.appendingPathComponent("sheeptext-md-hl", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("highlights.scm")
        if !fm.fileExists(atPath: dst.path) {
            try? fm.copyItem(at: src, to: dst)
        }
        return fm.fileExists(atPath: dst.path) ? dir : nil
    }

    // MARK: - Language mapping

    private static func mapLanguage(_ id: String) -> String? {
        switch id.lowercased() {
        case "cisco_ios", "cisco", "ios": return "cisco_ios"
        case "aruba_cx", "arubacx", "aoscx", "cx": return "aruba_cx"
        case "swift":                  return "swift"
        case "log":                    return "besttext_log"
        case "json", "jsonc":          return "json"
        case "javascript", "js", "jsx": return "javascript"
        case "typescript", "ts", "tsx": return "typescript"
        case "python", "py":           return "python"
        case "html", "htm":            return "html"
        case "css":                    return "css"
        case "go":                     return "go"
        case "rust", "rs":             return "rust"
        case "bash", "shell", "sh", "zsh", "fish": return "bash"
        case "ruby", "rb":             return "ruby"
        case "java":                   return "java"
        case "c", "h":                 return "c"
        case "csharp", "c#", "cs":     return "csharp"
        case "toml":                   return "toml"
        case "xml", "svg", "plist":    return "xml"
        case "dockerfile":             return "dockerfile"
        case "elixir", "ex", "exs":    return "elixir"
        case "scala":                  return "scala"
        case "haskell", "hs":          return "haskell"
        case "php":                    return "php"
        case "markdown", "md", "mdx":  return "markdown"
        case "yaml", "yml":            return "yaml"
        case "sql":                    return "sql"
        case "diff", "patch":          return "diff"
        default:                       return nil
        }
    }

    // MARK: - Bundle lookup

    private static func queriesURL(forBundleNamed bundleName: String) -> URL? {
        let fm = FileManager.default

        // Fast path: exact name inside every loaded bundle
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let url = bundle.url(forResource: bundleName, withExtension: "bundle"),
               let result = queriesIn(bundleURL: url, fm: fm) { return result }
        }

        // Slow path: SPM may use URL-derived identity with underscores instead of
        // the declared package name. Strip all non-letter characters and compare.
        guard let resourcesURL = Bundle.main.resourceURL,
              let contents = try? fm.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: nil)
        else { return nil }

        let target = bundleName.lowercased().filter(\.isLetter) 
        for candidateURL in contents where candidateURL.pathExtension == "bundle" {
            let candidate = candidateURL.deletingPathExtension().lastPathComponent
                .lowercased().filter(\.isLetter)
            if candidate == target, let result = queriesIn(bundleURL: candidateURL, fm: fm) {
                return result
            }
        }
        return nil
    }

    private static func queriesIn(bundleURL: URL, fm: FileManager) -> URL? {
        if let inner = Bundle(url: bundleURL), let res = inner.resourceURL {
            let url = res.appendingPathComponent("queries")
            if fm.isReadableFile(atPath: url.path) { return url }
        }
        let flat = bundleURL.appendingPathComponent("queries")
        if fm.isReadableFile(atPath: flat.path) { return flat }
        return nil
    }

    // MARK: - Colors

    private static func attributes(for captureName: String, isDark: Bool) -> [NSAttributedString.Key: Any] {
        let scope = normalizedScope(captureName)
        guard let pair = resolveTokenColor(scope) else { return [:] }
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: rgb(isDark ? pair.0 : pair.1)]
        if scope == "emphasis" || scope == "markup.italic" || scope == "text.emphasis" {
            attrs[.obliqueness] = 0.12
        }
        if scope == "emphasis.strong" || scope == "markup.bold" || scope == "text.strong" {
            attrs[.strokeWidth] = -2.0
        }
        return attrs
    }

    // Zed / tree-sitter-highlight hierarchical resolution:
    // "@keyword.function" → tries "keyword.function", then "keyword", then nil.
    private static func resolveTokenColor(_ scope: String) -> (UInt32, UInt32)? {
        var s = scope
        while !s.isEmpty {
            if let pair = tokenColors[s] { return pair }
            guard let dot = s.lastIndex(of: ".") else { break }
            s = String(s[s.startIndex..<dot])
        }
        return nil
    }

    // One Dark (dark) / One Light (light) — Zed default theme colors.
    // Keys are standard tree-sitter highlight names; the hierarchical resolver
    // above means "keyword.function" falls back to "keyword" automatically.
    private static let tokenColors: [String: (UInt32, UInt32)] = [
        // comments
        "comment":                    (0x5C6370, 0xA0A1A7),
        "comment.doc":                (0x5C6370, 0xA0A1A7),
        // strings
        "string":                     (0x98C379, 0x50A14F),
        "string.escape":              (0x56B6C2, 0x0184BC),
        "string.regex":               (0x98C379, 0x50A14F),
        "string.special":             (0x56B6C2, 0x0184BC),
        "string.special.symbol":      (0x56B6C2, 0x0184BC),
        // literals
        "number":                     (0xD19A66, 0x986801),
        "boolean":                    (0xD19A66, 0x986801),
        "character":                  (0xD19A66, 0x986801),
        // constants
        "constant":                   (0x56B6C2, 0x0184BC),
        "constant.builtin":           (0x56B6C2, 0x0184BC),
        // keywords — all subtypes (keyword.function, keyword.return, etc.) fall back here
        "keyword":                    (0xC678DD, 0xA626A4),
        "keyword.type":               (0x56B6C2, 0x0184BC),
        "keyword.directive":          (0xC678DD, 0xA626A4),
        // functions
        "function":                   (0x61AFEF, 0x4078F2),
        "function.builtin":           (0x56B6C2, 0x0184BC),
        "function.macro":             (0xC678DD, 0xA626A4),
        "function.method":            (0x61AFEF, 0x4078F2),
        "function.method.builtin":    (0x56B6C2, 0x0184BC),
        // types
        "constructor":                (0xE5C07B, 0xC18401),
        "constructor.builtin":        (0x56B6C2, 0x0184BC),
        "type":                       (0xE5C07B, 0xC18401),
        "type.builtin":               (0x56B6C2, 0x0184BC),
        "type.enum.variant":          (0x56B6C2, 0x0184BC),
        // attributes / decorators
        "attribute":                  (0xE5C07B, 0xC18401),
        // members
        "property":                   (0xE06C75, 0xE45649),
        "label":                      (0xE06C75, 0xE45649),
        // variables
        "variable":                   (0xABB2BF, 0x383A42),
        "variable.builtin":           (0xE06C75, 0xE45649),
        "variable.member":            (0xE06C75, 0xE45649),
        "variable.parameter":         (0xE06C75, 0xE45649),
        "variable.special":           (0xE06C75, 0xE45649),
        // HTML / JSX
        "tag":                        (0xE06C75, 0xE45649),
        "tag.attribute":              (0xE5C07B, 0xC18401),
        "tag.doctype":                (0xC678DD, 0xA626A4),
        // operators / punctuation
        "operator":                   (0xABB2BF, 0x383A42),
        "punctuation":                (0xABB2BF, 0x383A42),
        "punctuation.bracket":        (0xABB2BF, 0x383A42),
        "punctuation.delimiter":      (0xABB2BF, 0x383A42),
        "punctuation.list_marker":    (0xE06C75, 0xE45649),
        "punctuation.special":        (0x56B6C2, 0x0184BC),
        // embedded / misc
        "embedded":                   (0xABB2BF, 0x383A42),
        // markdown / rich text
        "title":                      (0xE5C07B, 0xC18401),
        "emphasis":                   (0xABB2BF, 0x383A42),
        "emphasis.strong":            (0xABB2BF, 0x383A42),
        "link_text":                  (0x61AFEF, 0x4078F2),
        "link_uri":                   (0x56B6C2, 0x0184BC),
        "text.literal":               (0x98C379, 0x50A14F),
        // markup.* aliases used by some grammars
        "markup.heading":             (0xE5C07B, 0xC18401),
        "markup.bold":                (0xABB2BF, 0x383A42),
        "markup.italic":              (0xABB2BF, 0x383A42),
        "markup.raw":                 (0x98C379, 0x50A14F),
        "markup.link":                (0x56B6C2, 0x0184BC),
        "markup.quote":               (0x5C6370, 0xA0A1A7),
        "markup.list":                (0xE06C75, 0xE45649),
        // SheepText log grammar
        "log.error":                  (0xE06C75, 0xE45649),
        "log.warning":                (0xD19A66, 0xC18401),
        "log.success":                (0x98C379, 0x50A14F),
        // diff grammar tokens
        "diff.plus":                  (0x98C379, 0x50A14F),
        "diff.minus":                 (0xE06C75, 0xE45649),
        "diff.delta":                 (0xD19A66, 0x986801),
        "diff.delta.moved":           (0x61AFEF, 0x4078F2),
        // SheepText UI tokens
        "hint":                       (0x5C6370, 0xA0A1A7),
        "predictive":                 (0x4B5263, 0xBBBFC6),
        "primary":                    (0xABB2BF, 0x383A42),
        // Error / invalid token (used by regex-based highlighters)
        "error":                      (0xFF5F57, 0xE45649),
    ]

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed:   CGFloat((hex >> 16) & 0xFF) / 255.0,
            green:     CGFloat((hex >> 8)  & 0xFF) / 255.0,
            blue:      CGFloat( hex        & 0xFF) / 255.0,
            alpha: 1
        )
    }

    private static func normalizedScope(_ captureName: String) -> String {
        captureName
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .replacingOccurrences(of: "syntax.", with: "")
    }

    // MARK: - Aruba CX network highlighter

    private struct ArubaHighlightRule {
        let scope: String
        let regex: NSRegularExpression
    }

    /// Same ordered rule set as SheepTerm. Earlier rules claim their ranges so,
    /// for example, VLAN lists win over interface names and MAC addresses win
    /// over IPv6-looking text.
    private static let arubaHighlightRules: [ArubaHighlightRule] = {
        let definitions: [(String, String, NSRegularExpression.Options)] = [
            ("comment", #"^[ \t]*!.*$"#, [.anchorsMatchLines]),
            ("number", #"\bvlan[ \t-]+\d{1,4}(?:[ \t]*[,\-][ \t]*\d{1,4})*"#, [.caseInsensitive]),
            ("constructor", #"\b(?:GigabitEthernet|TenGigabitEthernet|TwoGigabitEthernet|TwentyFiveGigE|FortyGigabitEthernet|HundredGigE|AppGigabitEthernet|FastEthernet|Port-channel|Bundle-Ether|Ethernet|Loopback|Tunnel|Management|Serial|Vlan|Gi|Twe|Tw|Te|Fo|Hu|Fa|Eth|Po|Lo|Se|lag|Trk|mgmt|ens|eno|bond|br)\s?\d+(?:[\/.:_-]\d+)*\b"#, [.caseInsensitive]),
            ("constructor", #"\b\d{1,2}/\d{1,2}/\d{1,2}(?::\d)?\b"#, []),
            ("keyword", #"\b255(?:\.\d{1,3}){3}\b"#, []),
            ("keyword", #"(?<=\d)/\d{1,2}\b"#, []),
            ("constant", #"\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b"#, []),
            ("property", #"\b(?:[0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}\b|\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"#, []),
            ("constant", #"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"#, []),
            ("string", #"\b(?:no[ \t]+shutdown|up|connected|active|established|running|enabled?|successful|success|forwarding|permit(?:ted|s)?|reachable|authorized|full|allow(?:ed)?)\b"#, [.caseInsensitive]),
            ("log.warning", #"\b(?:warning|warn)\b"#, [.caseInsensitive]),
            ("error", #"\b(?:down|shutdown|err-disabled|errdisable|notconnect|fail(?:ed|ure)?|den(?:y|ied)|unreachable|invalid|error|err|crit(?:ical)?|emergency|alert|blocked|blocking|discarding|disabled?|suspended|violation|half)\b"#, [.caseInsensitive]),
        ]
        return definitions.compactMap { scope, pattern, options in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return ArubaHighlightRule(scope: scope, regex: regex)
        }
    }()

    private static func arubaCxHighlight(text: String, isDark: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        guard fullRange.length > 0 else { return output }

        var claimed = IndexSet()
        for rule in arubaHighlightRules {
            let attrs = attributes(for: rule.scope, isDark: isDark)
            guard !attrs.isEmpty else { continue }
            rule.regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound, range.length > 0 else { return }
                let span = range.location..<NSMaxRange(range)
                // `contains(integersIn:)` answers the same question as building
                // an IndexSet per match and intersecting it, without allocating
                // one IndexSet per match across 11 rules.
                guard !claimed.intersects(integersIn: span) else { return }
                output.addAttributes(attrs, range: range)
                claimed.insert(integersIn: span)
            }
        }
        return output
    }

    // MARK: - Cisco IOS regex highlighter

    private static let ciscoSpanningTreeModes: Set<String> = [
        "pvst", "rapid-pvst", "mst", "rstp", "rpvst"
    ] 

    private static let ciscoSubKeywords: Set<String> = [
        "mode", "access", "trunk", "native", "allowed", "encapsulation",
        "dot1q", "add", "remove", "except", "all", "none"
    ]

    private static func ciscoIosHighlight(text: String, isDark: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: text)
        let nsText = text as NSString
        nsText.enumerateSubstrings(in: NSRange(location: 0, length: nsText.length),
                                   options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let lineStr = nsText.substring(with: lineRange)
            Self.highlightCiscoLine(lineStr, offset: lineRange.location, into: output, isDark: isDark)
        }

        return output
    }

    private static func highlightCiscoLine(
        _ line: String,
        offset: Int,
        into output: NSMutableAttributedString,
        isDark: Bool
    ) {
        let ns = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Comment lines (Cisco uses ! for comments)
        if trimmed.hasPrefix("!") {
            output.addAttributes(attributes(for: "comment", isDark: isDark),
                                 range: NSRange(location: offset, length: ns.length))
            return
        }

        // Tokenize: collect (text, range_in_line) pairs, skipping whitespace
        var tokens: [(text: String, range: NSRange)] = []
        var pos = 0
        while pos < ns.length {
            // Skip whitespace
            while pos < ns.length {
                let c = ns.character(at: pos)
                if c == 32 || c == 9 { pos += 1 } else { break }
            }
            guard pos < ns.length else { break }
            // Read token
            let start = pos
            while pos < ns.length {
                let c = ns.character(at: pos)
                if c == 32 || c == 9 { break }
                pos += 1
            }
            let tokRange = NSRange(location: offset + start, length: pos - start)
            let tokText = ns.substring(with: NSRange(location: start, length: pos - start))
            tokens.append((tokText, tokRange))
        }
        guard !tokens.isEmpty else { return }

        let cmd = tokens[0].text.lowercased()

        // First token is always a keyword
        output.addAttributes(attributes(for: "keyword", isDark: isDark), range: tokens[0].range)

        switch cmd {
        case "vlan":
            // vlan <id-list>  or  vlan <id>  (interface-mode)
            if tokens.count >= 2 {
                highlightVlanList(tokens[1].text, at: tokens[1].range, into: output, isDark: isDark)
            }
            for tok in tokens.dropFirst(2) {
                highlightGenericValue(tok, into: output, isDark: isDark)
            }

        case "spanning-tree":
            // spanning-tree mode <mode>
            // spanning-tree vlan <list> priority <value>
            if tokens.count >= 2 {
                let sub = tokens[1].text.lowercased()
                if ciscoSubKeywords.contains(sub) {
                    output.addAttributes(attributes(for: "keyword", isDark: isDark), range: tokens[1].range)
                    if sub == "mode", tokens.count >= 3 {
                        let modeToken = tokens[2]
                        let mode = modeToken.text.lowercased()
                        if ciscoSpanningTreeModes.contains(mode) {
                            output.addAttributes(attributes(for: "constant", isDark: isDark), range: modeToken.range)
                        } else {
                            output.addAttributes(attributes(for: "error", isDark: isDark), range: modeToken.range)
                        }
                        for tok in tokens.dropFirst(3) {
                            highlightGenericValue(tok, into: output, isDark: isDark)
                        }
                    } else {
                        for tok in tokens.dropFirst(2) {
                            highlightGenericValue(tok, into: output, isDark: isDark)
                        }
                    }
                } else {
                    for tok in tokens.dropFirst(1) {
                        highlightGenericValue(tok, into: output, isDark: isDark)
                    }
                }
            }

        default:
            for tok in tokens.dropFirst() {
                let lower = tok.text.lowercased()
                if ciscoSubKeywords.contains(lower) {
                    output.addAttributes(attributes(for: "keyword", isDark: isDark), range: tok.range)
                } else {
                    highlightGenericValue(tok, into: output, isDark: isDark)
                }
            }
        }
    }

    /// Highlight a VLAN list like `1,3,23,101-102,306s` — each item individually.
    private static func highlightVlanList(
        _ list: String,
        at listRange: NSRange,
        into output: NSMutableAttributedString,
        isDark: Bool
    ) {
        let ns = list as NSString
        // Split by comma, preserving positions
        var searchFrom = 0
        while searchFrom <= ns.length {
            let commaRange = ns.range(of: ",", range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            let end = commaRange.location == NSNotFound ? ns.length : commaRange.location
            let itemLen = end - searchFrom
            if itemLen > 0 {
                let item = ns.substring(with: NSRange(location: searchFrom, length: itemLen))
                let absRange = NSRange(location: listRange.location + searchFrom, length: itemLen)
                if isValidVlanItem(item) {
                    output.addAttributes(attributes(for: "number", isDark: isDark), range: absRange)
                } else {
                    output.addAttributes(attributes(for: "error", isDark: isDark), range: absRange)
                }
            }
            if commaRange.location == NSNotFound { break }
            // Highlight the comma as punctuation
            let commaAbsRange = NSRange(location: listRange.location + commaRange.location, length: 1)
            output.addAttributes(attributes(for: "punctuation", isDark: isDark), range: commaAbsRange)
            searchFrom = commaRange.location + 1
        }
    }

    private static func isValidVlanItem(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Single VLAN ID: pure digits, 1-4094
        if let n = Int(t), n >= 1, n <= 4094 { return true }
        // Range: <start>-<end>
        let parts = t.split(separator: "-", maxSplits: 1)
        if parts.count == 2,
           let a = Int(parts[0]), let b = Int(parts[1]),
           a >= 1, a <= 4094, b >= 1, b <= 4094, a <= b { return true }
        return false
    }

    private static func highlightGenericValue(
        _ tok: (text: String, range: NSRange),
        into output: NSMutableAttributedString,
        isDark: Bool
    ) {
        let t = tok.text
        if t.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) && !t.isEmpty {
            output.addAttributes(attributes(for: "number", isDark: isDark), range: tok.range)
        }
        // Strings that don't look like a valid identifier at all get no extra color (inherit default)
    }

    // MARK: - Grammar registry

    private struct GrammarSpec: Sendable {
        let name: String
        let bundleName: String
        let language: @Sendable () -> OpaquePointer?
    }

    private static let grammarSpecs: [String: GrammarSpec] = [
        "swift": GrammarSpec(
            name: "Swift",
            bundleName: "TreeSitterSwift_TreeSitterSwift",
            language: tree_sitter_swift
        ),
        "besttext_log": GrammarSpec(
            name: "SheepTextLog",
            bundleName: "TreeSitterBestTextLog_TreeSitterBestTextLog",
            language: tree_sitter_besttext_log
        ),
        "json": GrammarSpec(
            name: "JSON",
            bundleName: "TreeSitterJSON_TreeSitterJSON",
            language: tree_sitter_json
        ),
        "javascript": GrammarSpec(
            name: "JavaScript",
            bundleName: "TreeSitterJavaScript_TreeSitterJavaScript",
            language: tree_sitter_javascript
        ),
        "typescript": GrammarSpec(
            name: "TypeScript",
            bundleName: "TreeSitterTypeScript_TreeSitterTypeScript",
            language: tree_sitter_typescript
        ),
        "python": GrammarSpec(
            name: "Python",
            bundleName: "TreeSitterPython_TreeSitterPython",
            language: tree_sitter_python
        ),
        "html": GrammarSpec(
            name: "HTML",
            bundleName: "TreeSitterHTML_TreeSitterHTML",
            language: tree_sitter_html
        ),
        "css": GrammarSpec(
            name: "CSS",
            bundleName: "TreeSitterCSS_TreeSitterCSS",
            language: tree_sitter_css
        ),
        "markdown": GrammarSpec(
            name: "Markdown",
            bundleName: "TreeSitterMarkdown_TreeSitterMarkdown",
            language: tree_sitter_markdown
        ),
        "go": GrammarSpec(
            name: "Go",
            bundleName: "TreeSitterGo_TreeSitterGo",
            language: tree_sitter_go
        ),
        "rust": GrammarSpec(
            name: "Rust",
            bundleName: "TreeSitterRust_TreeSitterRust",
            language: tree_sitter_rust
        ),
        "bash": GrammarSpec(
            name: "Bash",
            bundleName: "TreeSitterBash_TreeSitterBash",
            language: tree_sitter_bash
        ),
        "ruby": GrammarSpec(
            name: "Ruby",
            bundleName: "TreeSitterRuby_TreeSitterRuby",
            language: tree_sitter_ruby
        ),
        "java": GrammarSpec(
            name: "Java",
            bundleName: "TreeSitterJava_TreeSitterJava",
            language: tree_sitter_java
        ),
        "c": GrammarSpec(
            name: "C",
            bundleName: "TreeSitterC_TreeSitterC",
            language: tree_sitter_c
        ),
        "csharp": GrammarSpec(
            name: "C#",
            bundleName: "TreeSitterCSharp_TreeSitterCSharp",
            language: tree_sitter_c_sharp
        ),
        "toml": GrammarSpec(
            name: "TOML",
            bundleName: "TreeSitterTOML_TreeSitterTOML",
            language: tree_sitter_toml
        ),
        "xml": GrammarSpec(
            name: "XML",
            bundleName: "TreeSitterXML_TreeSitterXML",
            language: tree_sitter_xml
        ),
        "dockerfile": GrammarSpec(
            name: "Dockerfile",
            bundleName: "TreeSitterDockerfile_TreeSitterDockerfile",
            language: tree_sitter_dockerfile
        ),
        "elixir": GrammarSpec(
            name: "Elixir",
            bundleName: "TreeSitterElixir_TreeSitterElixir",
            language: tree_sitter_elixir
        ),
        "scala": GrammarSpec(
            name: "Scala",
            bundleName: "TreeSitterScala_TreeSitterScala",
            language: tree_sitter_scala
        ),
        "haskell": GrammarSpec(
            name: "Haskell",
            bundleName: "TreeSitterHaskell_TreeSitterHaskell",
            language: tree_sitter_haskell
        ),
        "php": GrammarSpec(
            name: "PHP",
            bundleName: "TreeSitterPHP_TreeSitterPHP",
            language: tree_sitter_php
        ),
        "yaml": GrammarSpec(
            name: "YAML",
            bundleName: "TreeSitterYAML_TreeSitterYAML",
            language: tree_sitter_yaml
        ),
        "sql": GrammarSpec(
            name: "SQL",
            bundleName: "TreeSitterSql_TreeSitterSql",
            language: tree_sitter_sql
        ),
        "diff": GrammarSpec(
            name: "Diff",
            bundleName: "TreeSitterDiff_TreeSitterDiff",
            language: tree_sitter_diff
        ),
    ]
}
