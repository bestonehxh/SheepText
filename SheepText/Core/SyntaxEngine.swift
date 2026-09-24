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
//    LanguageConfiguration failure path on embedded injection predicates. Its
//    fenced code blocks are found by a one-pattern query compiled here
//    (`markdownInjectionQuerySource`) and run against the same tree, so Markdown
//    takes the ordinary incremental path — see `markdownFences`.
//

import Foundation
import AppKit
import NetworkHighlightKit
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
import TreeSitterMarkdownInline
import TreeSitterMarkdownInline
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

/// What one highlight pass produces: a sorted, non-overlapping run list over
/// the **full text**, in UTF-16 offsets, plus the changed-ranges contract.
///
/// This used to be a document-sized `NSAttributedString` that the editor copied
/// into its `NSTextStorage` — see the header of `HighlightRuns.swift` for why
/// it is a run list now. `[HighlightRun]` is a value type of trivial elements,
/// so nothing here is an unchecked concurrency boundary any more.
nonisolated struct SyntaxHighlightRuns: Sendable {
    let runs: [HighlightRun]
    /// nil means the whole document must be repainted. An empty array means the
    /// previous run list is still correct once shifted by the edit.
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
        let text: String
        let tree: Tree?
        /// The previous pass's finished run list. Reused as the base for the
        /// next incremental pass so a keystroke does not re-derive a run for
        /// every token in the document.
        ///
        /// There is deliberately no `isDark` here: runs carry a style id, not a
        /// colour, so the same session serves both appearances and flipping the
        /// theme costs no parse at all.
        let runs: [HighlightRun]?
        let anchors: [PointAnchor]
    }

    /// A session pins the document's full text, a copy of its syntax tree and
    /// its last run list. Closing a tab calls `discardSession`; this
    /// cap is the backstop for anything that does not (compare panes, snapshots,
    /// documents replaced in place).
    private static let sessionLimit = 8
    private var sessions: [UUID: ParseSession] = [:]
    private var sessionOrder: [UUID] = []

    /// Passes enqueued on `queue` and not yet finished.
    ///
    /// `queue` is ONE serial queue shared by every document, so a `queue.sync`
    /// from the main actor waits for everything ahead of it as well as for its
    /// own work — and nothing bounds what is ahead. A document only escapes the
    /// engine at `LargeFilePolicy`'s thresholds (10 MB / 100 000 lines /
    /// 1 000 000 characters), so the worst case queued in front of a
    /// `runsImmediately` is a clean pass over a 999 999-character document.
    /// See `runsImmediately`.
    ///
    /// Counted at ENQUEUE, not at the start of the work, so a caller that has
    /// just handed the engine an async pass sees a busy queue on the very next
    /// line. Kept under a lock rather than inside `queue` for the same reason:
    /// asking `queue` whether `queue` is busy means waiting for it.
    private let inFlightLock = NSLock()
    private var inFlightPasses = 0

    private func beginQueuedPass() {
        inFlightLock.lock(); inFlightPasses += 1; inFlightLock.unlock()
    }
    private func endQueuedPass() {
        inFlightLock.lock(); inFlightPasses -= 1; inFlightLock.unlock()
    }
    private var queueIsBusy: Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlightPasses > 0
    }

    init() {}

    /// Release the incremental-parse state for a document.
    ///
    /// Sessions used to be write-only: every highlight pass inserted one and
    /// nothing ever removed it, so every document opened in the process stayed
    /// resident — text, tree and run list — until the app quit.
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
        // `network_config` is a byte scanner plus a vendor table, not a grammar.
        if NetworkConfigLanguage.isNetworkConfig(mapped) { return true }
        // Tree-sitter languages require the grammar spec to exist.
        return grammarSpecs[mapped] != nil
    }

    /// The editor's path: parse off the main thread, hand back runs.
    ///
    /// No `isDark`: the result is appearance-independent, so an appearance
    /// change repaints from the run list the editor already holds and never
    /// reaches the engine at all.
    @MainActor
    func highlightRuns(
        text: String,
        language: String,
        documentID: UUID,
        completion: @escaping @MainActor @Sendable (_ result: SyntaxHighlightRuns?) -> Void
    ) {
        // No generation filter here on purpose. There used to be one counter for
        // the whole process, so a request from ANY editor cancelled the pending
        // completion of every other one — with two windows open, one of them
        // simply never got its highlights. Staleness is the caller's business and
        // every caller already checks: EditorView.Coordinator carries its own
        // per-coordinator `highlightGeneration` and drops late results.
        beginQueuedPass()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.endQueuedPass() }
            let result = self.highlightRuns(
                for: text,
                language: language,
                documentID: documentID
            )
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// One-shot runs for a snippet with no session — used to colour the visible
    /// region of a freshly opened tab before the whole-file pass lands. The
    /// caller offsets the ranges itself.
    @MainActor
    func snapshotRuns(
        text: String,
        language: String,
        completion: @escaping @MainActor @Sendable (_ runs: [HighlightRun]?) -> Void
    ) {
        beginQueuedPass()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.endQueuedPass() }
            let result = self.highlightRuns(for: text, language: language)
            DispatchQueue.main.async {
                completion(result?.runs)
            }
        }
    }

    /// Synchronous runs. `DocumentStore` uses it to precompute the first paint
    /// of a newly opened file.
    ///
    /// **It gives up rather than join a queue it does not control.**
    /// `precomputeInitialHighlight` caps its own input at 40 000 UTF-16 units,
    /// which bounds the work this call does — but `queue` is one serial queue
    /// shared by every document, so a `queue.sync` also waits for whatever is
    /// already on it, and nothing bounds THAT: a document stays inside the
    /// engine up to `LargeFilePolicy`'s 1 000 000 characters. Open a ~900 KB
    /// markdown file and open a second file while its first pass is running,
    /// and the main thread waited for the whole of it — measured at 1.2 s on a
    /// 400 KB fixture — on a path whose entire purpose is "the first frame is
    /// already coloured".
    ///
    /// `nil` is already the "no precompute" answer every caller handles: the
    /// ordinary async pass plus `applyVisibleHighlight`'s `snapshotRuns` colour
    /// the first screen, and that path already deals with runs arriving late.
    func runsImmediately(
        text: String,
        language: String,
        documentID: UUID? = nil
    ) -> SyntaxHighlightRuns? {
        guard !queueIsBusy else { return nil }
        beginQueuedPass()
        defer { endQueuedPass() }
        return queue.sync {
            highlightRuns(for: text, language: language, documentID: documentID)
        }
    }

    /// Compatibility shim: the same pass, materialised as an
    /// `NSAttributedString` under one appearance.
    ///
    /// **The editor never calls this.** It exists for the tests and benchmarks
    /// that compare two passes attribute for attribute, which is the same
    /// comparison as run-list equality plus a fixed palette, and is easier to
    /// read in a failure message.
    func highlightImmediately(
        text: String,
        language: String,
        isDark: Bool,
        documentID: UUID? = nil
    ) -> NSAttributedString? {
        guard let result = runsImmediately(text: text, language: language, documentID: documentID)
        else { return nil }
        return HighlightRunList.attributedString(text: text, runs: result.runs, isDark: isDark)
    }

    #if DEBUG
    /// Test seam. Same call, with both halves of the result returned
    /// synchronously, so the changed-ranges contract — "the previous result and
    /// this one differ only inside these ranges" — can be tested directly
    /// instead of inferred.
    func highlightImmediatelyWithRanges(
        text: String,
        language: String,
        isDark: Bool,
        documentID: UUID? = nil
    ) -> (value: NSAttributedString, changedRanges: [NSRange]?)? {
        guard let result = runsImmediately(text: text, language: language, documentID: documentID)
        else { return nil }
        return (
            HighlightRunList.attributedString(text: text, runs: result.runs, isDark: isDark),
            result.changedRanges
        )
    }
    #endif

    func setTheme(_: String) {}

    // MARK: - Core

    #if DEBUG
    /// Counts passes through the parse/query core. The apply layer's claim —
    /// "an appearance change is a repaint, not a re-parse" — is asserted by
    /// watching this not move.
    nonisolated(unsafe) private(set) static var highlightPassCount = 0
    static func resetHighlightPassCountForTesting() { highlightPassCount = 0 }
    #endif

    private func highlightRuns(
        for text: String,
        language: String,
        documentID: UUID? = nil
    ) -> SyntaxHighlightRuns? {
        #if DEBUG
        Self.highlightPassCount += 1
        #endif
        guard let mapped = Self.mapLanguage(language) else { return nil }

        let priorSession = documentID.flatMap { sessions[$0] }
        let textEdit = priorSession.flatMap { session -> IncrementalTextEdit? in
            guard session.language == mapped, session.text != text else { return nil }
            return Self.incrementalEdit(from: session.text, to: text, anchors: session.anchors)
        }

        let nsText = text as NSString
        let sourceLength = nsText.length
        let fullRange = NSRange(location: 0, length: sourceLength)

        if let vendor = NetworkConfigLanguage.vendor(forEngineLanguage: mapped) {
            let ranges = textEdit.map { Self.paragraphRanges([$0.newRange], in: text) }

            // Same reuse the tree-sitter path gets, and for the same reason:
            // the scan was never the expensive part here either — rebuilding
            // the whole output every keystroke was. Both layers of
            // `NetworkConfigHighlighter` are line-local, so shifting the
            // previous runs by the edit and re-running only the paragraphs it
            // touched is exact, not an approximation.
            var reused: [HighlightRun]?
            if let edit = textEdit,
               let ranges,
               let prior = priorSession?.runs {
                var painter = HighlightRunPainter(bounds: ranges.map { NSIntersectionRange($0, fullRange) })
                for range in ranges where NSMaxRange(range) <= sourceLength {
                    NetworkConfigHighlighter.highlight(
                        text: text, nsText: nsText, in: range,
                        vendor: vendor, into: &painter
                    )
                }
                let shifted = HighlightRunList.shifting(
                    prior,
                    replacing: edit.oldRange,
                    withLength: edit.newRange.length
                )
                reused = HighlightRunList.replacing(shifted, in: ranges, with: painter.runs())
            }

            let runs: [HighlightRun]
            if let reused {
                runs = reused
            } else {
                var painter = HighlightRunPainter(bounds: fullRange)
                NetworkConfigHighlighter.highlight(
                    text: text, nsText: nsText, in: fullRange,
                    vendor: vendor, into: &painter
                )
                runs = painter.runs()
            }

            if let documentID {
                storeSession(
                    ParseSession(
                        language: mapped,
                        text: text,
                        tree: nil,
                        runs: runs,
                        anchors: textEdit?.anchors ?? []
                    ),
                    for: documentID
                )
            }
            // `ranges` stays valid on the full-rebuild fallback too: it is only
            // non-nil when a prior session for the same document and language
            // existed, and line-locality means no line outside the edited
            // paragraphs can have changed colour.
            return SyntaxHighlightRuns(runs: runs, changedRanges: ranges)
        }

        guard let config = configuration(for: mapped),
              let parser = cachedParser(for: mapped, config: config)
        else { return nil }

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
            return nil
        }

        guard let query = config.queries[.highlights] else { return nil }

        let context = Predicate.Context(string: text)
        let injectionQuery = config.queries[.injections]

        // Markdown's injection regions — fenced code blocks and `inline` nodes
        // — and the changed ranges grown to cover them. See
        // `markdownInjectionScan`.
        //
        // A markdown pass that cannot compile the query must not reuse
        // anything: it would hand back changed ranges computed without knowing
        // where the injections are.
        var injections: [MarkdownInjection] = []
        var markdownInjectionsUnavailable = false
        if mapped == "markdown" {
            if let injectionsQuery = markdownInjectionQuery(for: config) {
                (injections, changedRanges) = markdownInjectionScan(
                    query: injectionsQuery,
                    tree: tree,
                    text: text,
                    nsText: nsText,
                    fullRange: fullRange,
                    changedRanges: changedRanges
                )
            } else {
                markdownInjectionsUnavailable = true
            }
        }

        if markdownInjectionsUnavailable { changedRanges = nil }
        let canReuse = !markdownInjectionsUnavailable

        // Every other injected language needs the same widening markdown's
        // fences get, and for a reason that is a property of INJECTION rather
        // than of markdown: the region is styled by a parser the outer tree
        // knows nothing about, so an edit inside it can recolour lines that
        // tree does not report. HTML sees a `<script>` body as one `raw_text`
        // token whose extent did not change, so opening a block comment on its
        // first line came back as one changed line — `applyInjections` re-parsed
        // the whole script and produced the right runs, and the painter's
        // bounds then clipped all of them away except the edited line.
        if canReuse, let injectionQuery, let ranges = changedRanges {
            changedRanges = Self.injectionWidenedRanges(
                query: injectionQuery, tree: tree, context: context,
                text: text, fullRange: fullRange, ranges: ranges
            )
        }

        var queryRanges: [NSRange]?
        if canReuse, textEdit != nil, let ranges = changedRanges, priorSession?.runs != nil {
            queryRanges = ranges.filter { NSMaxRange($0) <= sourceLength }
        }

        var painter = HighlightRunPainter(
            bounds: (queryRanges ?? [fullRange]).map { NSIntersectionRange($0, fullRange) }
        )

        // Primary language highlights
        for range in queryRanges ?? [fullRange] {
            Self.applyHighlights(
                query: query,
                tree: tree,
                context: context,
                restrictedTo: queryRanges == nil ? nil : range,
                fullRange: fullRange,
                into: &painter
            )
        }

        // Markdown: injections.scm can't be loaded for either markdown grammar
        // (LanguageConfiguration fails on its predicate syntax and node types),
        // so the nodes located above stand in for the injection query.
        if !injections.isEmpty {
            let bounds = queryRanges ?? [fullRange]
            for injection in injections
            where bounds.contains(where: { Self.touches($0, injection.block) }) {
                highlightMarkdownInjection(
                    injection, nsText: nsText, fullRange: fullRange, into: &painter
                )
            }
        }

        // Injected language highlights — same mechanism Zed uses.
        if let injectionQuery {
            // One pass over the UNION of the changed ranges, not one pass per
            // range. `applyInjections` re-parses the entire injected region for
            // every site that intersects its restriction, so an edit that
            // produced three changed paragraphs inside one 2000-line <script>
            // used to parse that whole script three times. The results are
            // identical (the pass is idempotent), so this is cost, not
            // correctness.
            applyInjections(
                query: injectionQuery,
                tree: tree,
                context: context,
                restrictedTo: queryRanges.flatMap { Self.unionRange(of: $0) },
                nsText: nsText,
                fullRange: fullRange,
                into: &painter
            )
        }

        let painted = painter.runs()
        let finished: [HighlightRun]
        if let queryRanges, let prior = priorSession?.runs, let edit = textEdit {
            let shifted = HighlightRunList.shifting(
                prior,
                replacing: edit.oldRange,
                withLength: edit.newRange.length
            )
            finished = HighlightRunList.replacing(shifted, in: queryRanges, with: painted)
        } else {
            finished = painted
        }

        if let documentID, let savedTree = tree.copy() {
            storeSession(
                ParseSession(
                    language: mapped,
                    text: text,
                    tree: savedTree,
                    runs: canReuse ? finished : nil,
                    anchors: textEdit?.anchors ?? []
                ),
                for: documentID
            )
        }

        return SyntaxHighlightRuns(runs: finished, changedRanges: changedRanges)
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
        fullRange: NSRange,
        into painter: inout HighlightRunPainter
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
            // `none` is skipped by the painter, which is what keeps a capture
            // with no colour of its own from erasing the one underneath it —
            // the old `guard !attrs.isEmpty`.
            painter.paint(
                HighlightStyleTable.styleID(forCaptureComponents: highlight.nameComponents),
                in: hlRange
            )
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
        into painter: inout HighlightRunPainter
    ) {
        // The same injection site can be reported by more than one match (a
        // grammar's injections.scm often carries several patterns that resolve
        // to the same raw_text node). Parsing it once is enough.
        var visited: Set<InjectionSite> = []

        for injection in Self.injectionSites(
            query: injectionQuery, tree: tree, context: context,
            restrictedTo: range, fullRange: fullRange
        ) {
            let injRange = injection.range
            guard visited.insert(
                InjectionSite(name: injection.name, location: injRange.location, length: injRange.length)
            ).inserted else { continue }

            guard let injMapped = Self.mapLanguage(injection.name),
                  let injConfig = configuration(for: injMapped),
                  let injParser = cachedParser(for: injMapped, config: injConfig)
            else { continue }

            let injContent = nsText.substring(with: injRange)
            guard let injTree = injParser.parse(injContent),
                  let injQuery = injConfig.queries[.highlights]
            else { continue }

            // `resolve(with:)` builds a caching context — a `[NSRange: String]`
            // dictionary and two escaping closures — and a query with no
            // predicates has nothing to resolve. The length is
            // `injRange.length`; asking the substring for it bridges the string
            // back to `NSString` for a number already in hand.
            let injFullRange = NSRange(location: 0, length: injRange.length)
            let injCursor = injQuery.execute(in: injTree)
            let injHighlights = injQuery.hasPredicates
                ? injCursor.resolve(
                    with: SwiftTreeSitter.Predicate.Context(string: injContent)
                  ).highlights()
                : injCursor.highlights()

            for highlight in injHighlights {
                var hlRange = NSIntersectionRange(highlight.range, injFullRange)
                guard hlRange.length > 0 else { continue }
                hlRange.location += injRange.location
                hlRange = NSIntersectionRange(hlRange, fullRange)
                guard hlRange.length > 0 else { continue }
                painter.paint(
                    HighlightStyleTable.styleID(forCaptureComponents: highlight.nameComponents),
                    in: hlRange
                )
            }
        }
    }

    private struct InjectionSite: Hashable {
        let name: String
        let location: Int
        let length: Int
    }

    /// Where the injections query says another grammar's text lives, and which
    /// grammar. One place, so the widening below and the painting above can
    /// never disagree about what an injection site is — the same rule markdown
    /// states for `widening` and its highlight filter.
    private static func injectionSites(
        query: Query,
        tree: MutableTree,
        context: SwiftTreeSitter.Predicate.Context,
        restrictedTo range: NSRange?,
        fullRange: NSRange
    ) -> [(name: String, range: NSRange)] {
        guard let root = tree.rootNode else { return [] }
        let cursor = query.execute(node: root, in: tree)
        if let range, range.length > 0 {
            cursor.setRange(range)
            cursor.execute(query: query, node: root)
        }
        var sites: [(name: String, range: NSRange)] = []
        for injection in cursor.resolve(with: context).injections() {
            let injRange = NSIntersectionRange(injection.range, fullRange)
            guard injRange.length > 0 else { continue }
            sites.append((injection.name, injRange))
        }
        return sites
    }

    /// Grow `ranges` until they cover every injection region they OVERLAP, the
    /// same predicate and the same fixed point markdown's fences use. nil means
    /// it did not converge, i.e. repaint the document.
    private static func injectionWidenedRanges(
        query: Query,
        tree: MutableTree,
        context: SwiftTreeSitter.Predicate.Context,
        text: String,
        fullRange: NSRange,
        ranges: [NSRange]
    ) -> [NSRange]? {
        guard !ranges.isEmpty else { return ranges }
        var current = ranges
        for _ in 0..<wideningRoundLimit {
            let sites = injectionSites(
                query: query, tree: tree, context: context,
                restrictedTo: unionRange(of: current), fullRange: fullRange
            ).map(\.range)
            let widened = widening(current, toCover: sites)
            if widened == current { return current }
            current = paragraphRanges(widened, in: text)
        }
        return nil
    }

    /// Smallest range covering all of `ranges`, or nil when there are none.
    private static func unionRange(of ranges: [NSRange]) -> NSRange? {
        guard var union = ranges.first else { return nil }
        for range in ranges.dropFirst() { union = NSUnionRange(union, range) }
        return union
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
            // Widen by one UTF-16 unit on each side before asking for the line
            // range. Pressing Return in the middle of a line makes the edit's
            // `newRange` the terminator itself, and `lineRange(for:)` given a
            // terminator returns only the line that terminator CLOSES — the
            // tail that just became a line of its own was never in the result.
            // A caller that repaints only these ranges therefore left the tail
            // wearing the old line's colours: in network_config, splitting
            // `vlan 10 20` before ` 20` makes `20` the first token of its line
            // (keyword, purple) while the screen kept the old `number` orange.
            // Costs at most one extra line per range.
            let start = max(0, safe.location - 1)
            let end = min(ns.length, NSMaxRange(safe) + 1)
            return ns.lineRange(for: NSRange(location: start, length: end - start))
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

    // MARK: - Markdown fenced code blocks

    /// One region of a markdown document that another grammar highlights: a
    /// fenced code block, or an `inline` node.
    ///
    /// `block` is the whole node — for a fence, both delimiter lines, the info
    /// string and the body — and is what the changed-range widening covers.
    /// `content` is the part actually re-parsed: a fence's `code_fence_content`
    /// child, or the inline node itself. An empty fence has no content.
    private struct MarkdownInjection {
        let block: NSRange
        let content: NSRange?
        /// Lower-cased text of the `language` node inside `info_string`, or
        /// `markdown_inline`. Before `mapLanguage`. nil for an untagged fence,
        /// which injects nothing.
        let language: String?
    }

    /// This used to be an `NSRegularExpression` over the whole document, run on
    /// every markdown keystroke — and it was the single reason markdown could
    /// not reuse anything. It also disagreed with CommonMark in four places:
    /// it required a closing fence, it only knew backticks, it demanded the
    /// opener start in column 0, and it rejected any info string that carried
    /// more than the language word. The grammar has an opinion on all four and
    /// it is the right one.
    ///
    /// The `(inline)` pattern is the second half of markdown's injections: the
    /// block grammar leaves every paragraph, heading and list item's text as
    /// one opaque `inline` node, and the *inline* grammar is what finds the
    /// emphasis, strong, code spans and links in it. Both products ship in the
    /// one `TreeSitterMarkdown` package the app already links.
    private static let markdownInjectionQuerySource = """
    (fenced_code_block) @fence
    (inline) @inline
    """

    /// Compiled once per process, against the markdown grammar. `nil` in
    /// `markdownInjectionQueryFailed` is remembered the same way a failed
    /// configuration is: a query that will not compile will not compile on the
    /// next keystroke either.
    private var markdownInjectionQueryCache: Query?
    private var markdownInjectionQueryFailed = false

    private func markdownInjectionQuery(for config: LanguageConfiguration) -> Query? {
        if let existing = markdownInjectionQueryCache { return existing }
        if markdownInjectionQueryFailed { return nil }
        guard let query = try? Query(
            language: config.language,
            data: Data(Self.markdownInjectionQuerySource.utf8)
        ) else {
            markdownInjectionQueryFailed = true
            return nil
        }
        markdownInjectionQueryCache = query
        return query
    }

    /// Find the injection regions that matter for this pass, and grow the
    /// changed ranges to cover them.
    ///
    /// **The one markdown-specific rule**: a changed range grows to cover every
    /// fence it touches.
    ///
    /// A fence body is styled by a parser the markdown tree knows nothing
    /// about, so an edit inside it can recolour lines that tree does not
    /// report — to it the whole body is one opaque token whose extent did not
    /// change, so `changedRanges` comes back as the edited line alone. Turning
    /// `//` into `/*` on a fence's first body line is the measured case: every
    /// line below it becomes a comment, and without this rule the incremental
    /// run list keeps a stale keyword on the last one.
    ///
    /// The mirror image needs no rule. A fence that stops being a fence — a
    /// deleted opener, an opener indented to four spaces, a closing delimiter
    /// removed — is a change of node structure over the whole block, and that
    /// is exactly what `Tree.changedRanges(from:)` reports. Verified on a
    /// 60-line fence for each of those shapes; do not add a "regions the
    /// previous pass saw" list on the theory that it might be needed.
    ///
    /// Growing a range can bring it up against a fence the restricted query did
    /// not look for, so the scan repeats until the ranges stop growing. In
    /// practice that is one extra restricted query, and only when a fence was
    /// absorbed at all.
    private func markdownInjectionScan(
        query: Query,
        tree: MutableTree,
        text: String,
        nsText: NSString,
        fullRange: NSRange,
        changedRanges: [NSRange]?
    ) -> (injections: [MarkdownInjection], changedRanges: [NSRange]?) {
        guard var ranges = changedRanges else {
            return (
                Self.markdownInjections(
                    query: query, tree: tree, nsText: nsText,
                    fullRange: fullRange, restrictedTo: nil
                ),
                nil
            )
        }

        var found: [MarkdownInjection] = []
        for _ in 0..<Self.wideningRoundLimit {
            found = Self.markdownInjections(
                query: query, tree: tree, nsText: nsText,
                fullRange: fullRange, restrictedTo: Self.unionRange(of: ranges)
            )
            let widened = Self.widening(ranges, toCover: found.map(\.block))
            // Only re-line-align when a fence was actually absorbed.
            // `paragraphRanges` widens by one UTF-16 unit on each side before
            // snapping to line bounds, so running it again on ranges it already
            // produced quietly grows them by a line at each end — markdown
            // would repaint one line more than every other language, for no
            // reason, and a test written to catch a missing fence would pass on
            // that accident instead.
            //
            // Converged: `found` describes exactly the regions `ranges` covers,
            // which is the post-condition the caller needs.
            if widened == ranges { return (found, ranges) }
            ranges = Self.paragraphRanges(widened, in: text)
        }
        // Not converged. The loop used to stop here and return the ranges it
        // had just grown together with the injections it had found BEFORE that
        // growth — so a region absorbed on the last round was inside the
        // repainted bounds and not in the list, `HighlightRunList.replacing`
        // threw its runs away and nothing put them back. Measured on four
        // back-to-back fences followed by a paragraph: the paragraph's
        // `**bold**` lost its colour until a tab switch or a relaunch.
        //
        // `nil` is what "repaint the document" already means everywhere else,
        // and it is the only answer that is certainly right.
        return (
            Self.markdownInjections(
                query: query, tree: tree, nsText: nsText, fullRange: fullRange, restrictedTo: nil
            ),
            nil
        )
    }

    /// How many times a changed-range set may grow to swallow the injection
    /// regions it runs into before the pass gives up and repaints everything.
    ///
    /// Only an ABUTTING chain cascades — `paragraphRanges` widens by one line,
    /// so it reaches the next region only when that region starts on the line
    /// after — and a document made of back-to-back fenced blocks is the one
    /// shape that does it. Eight rounds covers every real document; a document
    /// that needs more pays one full pass per keystroke, which is correct and
    /// was the behaviour before incremental markdown existed at all.
    private static let wideningRoundLimit = 8

    /// The `fenced_code_block` and `inline` nodes in the tree, in document
    /// order.
    ///
    /// `restrictedTo` is the same restriction `applyHighlights` uses, and for
    /// the same reason: on a keystroke only the regions the changed ranges
    /// reach can matter, and walking the whole tree for the rest cost about
    /// 6 ms on a 50 000-character document — every keystroke. Pass nil on a
    /// full pass. Nothing outlives the pass, so a partial list is safe: the
    /// session stores runs and a tree, never injection regions.
    private static func markdownInjections(
        query: Query,
        tree: MutableTree,
        nsText: NSString,
        fullRange: NSRange,
        restrictedTo range: NSRange?
    ) -> [MarkdownInjection] {
        guard let root = tree.rootNode else { return [] }
        var found: [MarkdownInjection] = []
        let cursor = query.execute(node: root, in: tree)
        if let range, range.length > 0 {
            cursor.setRange(range)
            cursor.execute(query: query, node: root)
        }
        for match in cursor {
            for capture in match.captures {
                let node = capture.node
                let block = NSIntersectionRange(node.range, fullRange)
                guard block.length > 0 else { continue }

                if capture.name == "inline" {
                    guard Self.mayCarryInlineMarkup(nsText, in: block) else { continue }
                    found.append(MarkdownInjection(
                        block: block, content: block, language: Self.markdownInlineLanguage
                    ))
                    continue
                }

                var content: NSRange?
                var language: String?
                for index in 0..<node.namedChildCount {
                    guard let child = node.namedChild(at: index) else { continue }
                    switch child.nodeType {
                    case "code_fence_content":
                        let range = NSIntersectionRange(child.range, fullRange)
                        if range.length > 0 { content = range }
                    case "info_string":
                        for inner in 0..<child.namedChildCount {
                            guard let word = child.namedChild(at: inner),
                                  word.nodeType == "language" else { continue }
                            let range = NSIntersectionRange(word.range, fullRange)
                            if range.length > 0 {
                                language = nsText.substring(with: range).lowercased()
                            }
                            break
                        }
                    default:
                        break
                    }
                }
                found.append(MarkdownInjection(block: block, content: content, language: language))
            }
        }
        found.sort { $0.block.location < $1.block.location }
        return found
    }

    /// Re-parse one fence's body with the language its info string names and
    /// offset the highlights back into the document. Same shape as
    /// `applyInjections`, and it shares the per-language parser cache with it.
    private func highlightMarkdownInjection(
        _ injection: MarkdownInjection,
        nsText: NSString,
        fullRange: NSRange,
        into painter: inout HighlightRunPainter
    ) {
        guard let contentRange = injection.content,
              let language = injection.language,
              let mapped = Self.mapLanguage(language),
              let injConfig = configuration(for: mapped),
              let injParser = cachedParser(for: mapped, config: injConfig)
        else { return }

        let content = nsText.substring(with: contentRange)
        guard let injTree = injParser.parse(content),
              let injQuery = injConfig.queries[.highlights]
        else { return }

        // `markdown_inline`'s bundled highlights.scm has no predicates at all,
        // and on a full markdown pass there is one of these per paragraph,
        // heading and list item — so the caching context `resolve(with:)`
        // builds, a `[NSRange: String]` dictionary plus two escaping closures,
        // was allocated once per paragraph to resolve nothing.
        let injFullRange = NSRange(location: 0, length: contentRange.length)
        let injCursor = injQuery.execute(in: injTree)
        let injHighlights = injQuery.hasPredicates
            ? injCursor.resolve(with: Predicate.Context(string: content)).highlights()
            : injCursor.highlights()

        for highlight in injHighlights {
            var hlRange = NSIntersectionRange(highlight.range, injFullRange)
            guard hlRange.length > 0 else { continue }
            hlRange.location += contentRange.location
            hlRange = NSIntersectionRange(hlRange, fullRange)
            guard hlRange.length > 0 else { continue }
            painter.paint(
                HighlightStyleTable.styleID(forCaptureComponents: highlight.nameComponents),
                in: hlRange
            )
        }
    }

    /// Could the inline grammar produce any capture from this text?
    ///
    /// Every pattern in the inline grammar's highlights.scm is anchored on a
    /// character: `` ` `` for a code span, `*`/`_` for emphasis, `[`/`]`/`(`/`)`
    /// for links and images, `<` for an autolink, `\` for an escape, `&` for an
    /// entity, `!` for an image. A newline counts too, because a hard line
    /// break is two spaces before one.
    ///
    /// Without this, a 50 000-character document paid an inline parse for every
    /// paragraph and heading in it — roughly doubling a full pass. Plain prose
    /// is most of a markdown file and none of it can produce a capture.
    ///
    /// It is a pure function of the text, so a clean pass and an incremental
    /// pass always make the same decision — it cannot skew the changed-range
    /// contract.
    private static func mayCarryInlineMarkup(_ text: NSString, in range: NSRange) -> Bool {
        var buffer = CFStringInlineBuffer()
        CFStringInitInlineBuffer(text as CFString, &buffer, CFRangeMake(range.location, range.length))
        defer { withExtendedLifetime(text) {} }
        for index in 0..<range.length {
            switch CFStringGetCharacterFromInlineBuffer(&buffer, index) {
            case 0x60, 0x2A, 0x5F, 0x5B, 0x5D, 0x28, 0x29,
                 0x3C, 0x3E, 0x5C, 0x21, 0x26, 0x0A, 0x0D:
                return true
            default:
                continue
            }
        }
        return false
    }

    /// Do the two ranges share at least one character?
    ///
    /// Strictly overlap — abutting deliberately does NOT count. An edit that
    /// changes a fence always lands ON one of its lines (its opener, its body,
    /// its closer), so overlap is enough; counting the blank line after a fence
    /// as a touch made every prose edit between two fences absorb both of them
    /// and then, through `paragraphRanges` widening the result by a line again,
    /// cascade outwards until the whole document was in the repaint.
    ///
    /// `widening` and the highlight filter must use the SAME predicate: a fence
    /// inside the repainted bounds whose highlights are not re-run would have
    /// its runs cleared and never replaced.
    private static func touches(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0
    }

    /// Grow each range until it covers every range in `covers` that it touches.
    /// Repeated to a fixed point, because absorbing one fence can bring the
    /// range up against the next.
    private static func widening(_ ranges: [NSRange], toCover covers: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty, !covers.isEmpty else { return ranges }
        var out = ranges
        var rounds = 0
        var grew = true
        while grew, rounds <= covers.count {
            grew = false
            rounds += 1
            for cover in covers {
                for index in out.indices where touches(out[index], cover) {
                    let union = NSUnionRange(out[index], cover)
                    if !NSEqualRanges(union, out[index]) {
                        out[index] = union
                        grew = true
                    }
                }
            }
        }
        return out
    }

    // MARK: - Parser cache

    private func cachedParser(for language: String, config: LanguageConfiguration) -> Parser? {
        if let existing = parsers[language] { return existing }
        if failedParsers.contains(language) { return nil }
        let p = Parser()
        guard (try? p.setLanguage(config.language)) != nil else {
            // A failed `setLanguage` used to allocate and throw away a Parser on
            // every keystroke for the rest of the session.
            failedParsers.insert(language)
            return nil
        }
        parsers[language] = p
        return p
    }

    // MARK: - Configuration cache

    /// Successes are cached in `configurations` / `parsers`; failures used to be
    /// cached nowhere, so a language whose grammar bundle is missing or whose
    /// query fails to compile re-walked `Bundle.allBundles + allFrameworks`,
    /// stat'd two override paths and re-attempted the query compile on *every*
    /// highlight pass. Both sets are queue-confined like the caches beside them.
    ///
    /// The trade is that a grammar which appears later in the session (a
    /// user-installed query override) is not picked up until relaunch — the same
    /// trade the success caches already make.
    private var failedConfigurations: Set<String> = []
    private var failedParsers: Set<String> = []

    #if DEBUG
    /// Test seam: how many times `configuration(for:)` has fallen through to the
    /// bundle walk. A cached success or a remembered failure must not move it.
    nonisolated(unsafe) private(set) static var configurationLookupAttempts = 0

    @MainActor
    func lookUpConfigurationForTesting(_ language: String) -> Bool {
        queue.sync { configuration(for: language) != nil }
    }
    #endif

    private func configuration(for language: String) -> LanguageConfiguration? {
        if let existing = configurations[language] { return existing }
        if failedConfigurations.contains(language) { return nil }

        #if DEBUG
        Self.configurationLookupAttempts += 1
        #endif

        guard let spec = Self.grammarSpecs[language],
              let packageQueriesURL = Self.queriesURL(forBundleNamed: spec.bundleName),
              let tsLanguage = spec.language()
        else {
            failedConfigurations.insert(language)
            return nil
        }

        let candidateQueryURLs = Self.sheeptextQueryCandidates(for: language) + [packageQueriesURL]

        for candidateURL in candidateQueryURLs {
            // Both markdown grammars: their injections.scm carries `#set!`
            // predicates and node types (`latex_block`) the compiled grammar
            // may not have, either of which makes `LanguageConfiguration` throw
            // and lose the highlights query with it.
            let loadURL = Self.markdownQueryLanguages.contains(language)
                ? (Self.highlightsOnlyDirectory(from: candidateURL, language: language) ?? candidateURL)
                : candidateURL

            if let config = try? LanguageConfiguration(tsLanguage, name: spec.name, queriesURL: loadURL) {
                configurations[language] = config
                return config
            }
        }

        failedConfigurations.insert(language)
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

        let runtimeURL = AppStorageLocation.applicationSupport
            .appendingPathComponent("SheepTextTreeSitterQueries", isDirectory: true)
            .appendingPathComponent(language, isDirectory: true)
        if fm.fileExists(atPath: runtimeURL.appendingPathComponent("highlights.scm").path) {
            urls.append(runtimeURL)
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

    static let markdownInlineLanguage = "markdown_inline"
    private static let markdownQueryLanguages: Set<String> = ["markdown", markdownInlineLanguage]

    // Copies only highlights.scm into a temp directory so LanguageConfiguration
    // never sees injections.scm or locals.scm for either markdown grammar.
    //
    // The directory is per language. It used to be one shared
    // `sheeptext-md-hl`, with a `!fileExists` guard on the copy — so whichever
    // markdown grammar loaded first left ITS highlights.scm there and the other
    // one was handed it. The inline grammar then failed to compile a query full
    // of block node types, `LanguageConfiguration` threw, and inline
    // highlighting silently did not exist.
    //
    // The copy is unconditional. The `!fileExists` guard outlived the shared
    // directory, and the destination is the sandbox container's temporary
    // directory, which survives relaunches and app UPDATES until the OS decides
    // to clean it — so a shipped fix to the bundled `highlights.scm` was never
    // read, and a user's own override at
    // `Application Support/SheepText/SheepTextTreeSitterQueries/markdown/`
    // was copied to the path the bundled one already occupied and ignored.
    // `sheeptextQueryCandidates` puts the override first for every other
    // language; markdown and markdown_inline were the only two it could not
    // reach. One file copy per language per launch is the simplest thing that
    // is correct.
    // Not `private`: `SyntaxAudit2FixTests` checks the copy really does follow
    // its source, which is the whole of the fix above.
    static func highlightsOnlyDirectory(from queriesURL: URL, language: String) -> URL? {
        let fm = FileManager.default
        let src = queriesURL.appendingPathComponent("highlights.scm")
        guard fm.fileExists(atPath: src.path) else { return nil }

        let dir = fm.temporaryDirectory
            .appendingPathComponent("sheeptext-md-hl", isDirectory: true)
            .appendingPathComponent(language, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("highlights.scm")
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
        return fm.fileExists(atPath: dst.path) ? dir : nil
    }

    // MARK: - Language mapping

    private static func mapLanguage(_ id: String) -> String? {
        // Every network-config id — the plain one, a `network_config:<vendor>`
        // composite, and the `cisco_ios` / `aruba_cx` aliases 1.3.5 and earlier
        // wrote — normalises to ONE canonical composite. That makes the vendor
        // part of the session key for free: change vendor, and the reuse check
        // `session.language == mapped` fails, which is exactly right.
        if let vendor = NetworkConfigLanguage.vendor(forEngineLanguage: id) {
            return NetworkConfigLanguage.id + ":" + vendor.rawValue
        }
        switch id.lowercased() {
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
        case "markdown_inline":        return "markdown_inline"
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
    //
    // Token colours, the capture-name hierarchy and the memo that used to live
    // here are now `HighlightStyleTable` in `HighlightRuns.swift`: a pass
    // produces style ids, and only the editor — which knows the appearance and
    // owns the layout manager — turns an id into an `NSColor`.

    // MARK: - Network config
    //
    // The `cisco_ios` and `aruba_cx` highlighters that used to live here — an
    // ordered NSRegularExpression table for Aruba and a hand-rolled token
    // walker for Cisco — are `NetworkConfigHighlighter` in
    // `NetworkConfigHighlight.swift` now, over NetworkHighlightKit. Both ids
    // still resolve, as vendor aliases.

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
        // Not a language a document can be in — `LanguageDetector` never
        // returns it and it is not in `DocumentStore.supportedLanguages`. It
        // exists so the block grammar's `inline` nodes have something to inject.
        "markdown_inline": GrammarSpec(
            name: "MarkdownInline",
            bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline",
            language: tree_sitter_markdown_inline
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
