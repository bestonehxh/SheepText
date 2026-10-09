//
//  SyntaxEngine.swift
//  Syntax highlighting, powered by SheepSyntaxKit — SheepText's own
//  highlighter, pure Swift, no third-party code.
//
//  Architecture:
//  - One shared serial queue keeps all highlighting off the main thread.
//  - One `SyntaxHighlighter` per document, kept as a session. It remembers the
//    state every line starts in, so an edit re-lexes from the edited line and
//    stops as soon as a line past the edit starts in the state it had before.
//    The result is EXACTLY a clean pass — see SheepSyntaxKit/README.md.
//  - The kit reports `SyntaxScope`s; this file maps each one onto the app's
//    `HighlightStyleTable` once, by capture name. Nothing here knows about
//    colours or appearance.
//  - `network_config` goes through the same session type, as a
//    `SyntaxGrammar.networkConfig(vendor)`: SheepSyntaxKit's network lexer over
//    NetworkHighlightKit's scanner. The vendor is part of the grammar and of
//    the session key, so a vendor change starts a clean session.
//
//  Until September 2026 this file drove tree-sitter: a C runtime, a Swift wrapper, 22
//  grammar packages fetched from GitHub, a query compiler, markdown injection
//  queries and the widening rules they needed. All of that is gone.
//

import Foundation
import NetworkHighlightKit
import SheepSyntaxKit

// MARK: - Public API

/// What one highlight pass produces: a sorted, non-overlapping run list over
/// the **full text**, in UTF-16 offsets, plus the changed-ranges contract.
nonisolated struct SyntaxHighlightRuns: Sendable {
    let runs: [HighlightRun]
    /// nil means the whole document must be repainted. An empty array means the
    /// previous run list is still correct once shifted by the edit.
    let changedRanges: [NSRange]?
}

/// Sessions never escape the private serial queue.
nonisolated final class SyntaxEngine: @unchecked Sendable {

    static let shared = SyntaxEngine()

    private let queue = DispatchQueue(label: "sheeptext.syntax", qos: .userInitiated)

    /// A session: the highlighter holds the text, the line states and the
    /// run list itself. Reused only under the same grammar, so a language or
    /// vendor change starts clean.
    private struct Session {
        let grammar: SyntaxGrammar
        let highlighter: SyntaxHighlighter
    }

    /// A session pins the document's text and run list. Closing a tab calls
    /// `discardSession`; this cap is the backstop for anything that does not
    /// (compare panes, snapshots, documents replaced in place).
    static let sessionLimit = 8
    private var sessions: [UUID: Session] = [:]
    private var sessionOrder: [UUID] = []

    /// Passes enqueued on `queue` and not yet finished.
    ///
    /// `queue` is ONE serial queue shared by every document, so a `queue.sync`
    /// from the main actor waits for everything ahead of it as well as for its
    /// own work — and nothing bounds what is ahead. See `runsImmediately`.
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

    /// Release the incremental state for a document.
    func discardSession(for documentID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessions.removeValue(forKey: documentID)
            self.sessionOrder.removeAll { $0 == documentID }
        }
    }

    private func storeSession(_ session: Session, for documentID: UUID) {
        sessions[documentID] = session
        sessionOrder.removeAll { $0 == documentID }
        sessionOrder.append(documentID)
        while sessionOrder.count > Self.sessionLimit {
            let evicted = sessionOrder.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
    }

    static func supportsHighlighting(_ language: String) -> Bool {
        resolve(language) != nil
    }

    /// The editor's path: highlight off the main thread, hand back runs.
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
        // No generation filter here on purpose: staleness is the caller's
        // business, and EditorView.Coordinator's per-coordinator
        // `highlightGeneration` already drops late results.
        beginQueuedPass()
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.endQueuedPass() }
            let result = self.highlightRuns(for: text, language: language, documentID: documentID)
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
    /// **It gives up rather than join a queue it does not control.** `queue`
    /// is one serial queue shared by every document, so a `queue.sync` also
    /// waits for whatever is already on it. `nil` is already the "no
    /// precompute" answer every caller handles.
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
    /// that compare two passes attribute for attribute.
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
    /// Test seam: both halves of the result, synchronously, so the
    /// changed-ranges contract can be tested directly instead of inferred.
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
    /// Counts passes. The apply layer's claim — "an appearance change is a
    /// repaint, not a re-highlight" — is asserted by watching this not move.
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
        guard let grammar = Self.resolve(language) else { return nil }
        let prior = documentID.flatMap { sessions[$0] }.flatMap { $0.grammar == grammar ? $0 : nil }
        let highlighter = prior?.highlighter ?? SyntaxHighlighter(grammar: grammar)
        let update = highlighter.update(Array(text.utf16))
        if let documentID {
            storeSession(Session(grammar: grammar, highlighter: highlighter), for: documentID)
        }
        return SyntaxHighlightRuns(
            runs: Self.convert(update.runs),
            changedRanges: update.changedRanges?.map { NSRange(location: $0.lowerBound, length: $0.count) }
        )
    }

    // MARK: - Scope → style

    /// `SyntaxScope` → the app's style id, resolved once through the same
    /// capture-name hierarchy tree-sitter captures used.
    private static let styleForScope: [HighlightStyleID] = SyntaxScope.allCases.map {
        $0 == .none ? HighlightStyleTable.none : HighlightStyleTable.styleID(forCapture: $0.captureName)
    }

    private static func convert(_ runs: [SyntaxRun]) -> [HighlightRun] {
        var out: [HighlightRun] = []
        out.reserveCapacity(runs.count)
        for run in runs {
            let style = styleForScope[Int(run.scope.rawValue)]
            guard style != HighlightStyleTable.none else { continue }
            out.append(HighlightRun(location: run.location, length: run.length, style: style))
        }
        return out
    }

    // MARK: - Language mapping

    /// Every document language id, alias and legacy id to what highlights it.
    ///
    /// Every network-config id — the plain one, a `network_config:<vendor>`
    /// composite, and the `cisco_ios` / `aruba_cx` aliases 1.3.5 and earlier
    /// wrote — resolves to one `.networkConfig(vendor)`. That makes the vendor
    /// part of the session key for free: change vendor, and the reuse check
    /// fails, which is exactly right.
    private static func resolve(_ id: String) -> SyntaxGrammar? {
        if let vendor = NetworkConfigLanguage.vendor(forEngineLanguage: id) {
            return .networkConfig(vendor)
        }
        return SyntaxLanguage(identifier: id).map(SyntaxGrammar.language)
    }
}
