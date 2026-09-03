//
//  EditorView.swift
//  SwiftUI wrapper around the AppKit NSTextView subclass that does the real
//  editing work.
//
//  Changes in this version:
//    - Attaches a LineNumberRulerView as the scroll view's vertical ruler
//      so the user sees line numbers in a gutter.
//    - Listens to EditorTextView.selectionDidChange and updates the
//      shared CursorState (read by the status bar).
//
//  The TextKit stack is built manually to force TextKit 1 — our
//  multi-cursor code depends on NSLayoutManager / NSTextStorage semantics
//  that differ in TextKit 2.
//

import NetworkHighlightKit
import SwiftUI
import AppKit

private extension NSColor {
    static let editorBackground = NSColor(name: nil) { appearance in
        NSColor.bestTextEditorBackground(for: appearance)
    }

    static let editorForeground = NSColor(name: nil) { appearance in
        NSColor.bestTextEditorForeground(for: appearance)
    }
}

struct EditorView: View {

    @Environment(DocumentStore.self) private var documents
    @State private var findController = FindReplaceController()

    var body: some View {
        VStack(spacing: 0) {
            if findController.isVisible, documents.activeDocument != nil {
                FindReplaceBar(
                    controller: findController,
                    onNavigate: { range in
                        NotificationCenter.default.post(
                            name: .findBarNavigate,
                            object: nil,
                            userInfo: ["range": range]
                        )
                    },
                    onReplace: { range, replacement in
                        NotificationCenter.default.post(
                            name: .findBarReplace,
                            object: nil,
                            userInfo: ["range": range, "replacement": replacement]
                        )
                    },
                    onReplaceAll: { ranges, replacement in
                        NotificationCenter.default.post(
                            name: .findBarReplaceAll,
                            object: nil,
                            userInfo: [
                                "ranges": ranges.map { NSValue(range: $0) },
                                "replacement": replacement
                            ]
                        )
                    },
                    currentText: {
                        // Must be the exact string the match ranges will be applied
                        // to. document.text is not that string: it omits compare
                        // mode's filler lines and expands folds, so every offset
                        // past the first difference landed on the wrong character.
                        EditorCommandTarget.focusedEditor?.string
                            ?? documents.activeDocument?.text
                            ?? ""
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                if let left = documents.compareLeftDocument,
                   let right = documents.compareRightDocument,
                   left.id != right.id {
                    CompareModeView(left: left, right: right)
                } else if let doc = documents.activeDocument {
                    EditorRepresentable(document: doc)
                } else {
                    EmptyStateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .editorBackground))
            .clipped()
        }
        .animation(.snappy(duration: 0.15), value: findController.isVisible)
        .onReceive(NotificationCenter.default.publisher(for: .findBarShow)) { _ in
            findController.show(withReplace: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findBarShowWithReplace)) { _ in
            findController.show(withReplace: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .findBarHide)) { _ in
            findController.hide()
        }
    }
}

private struct CompareModeView: View {
    let left: Document
    let right: Document

    @Environment(DocumentStore.self) private var documents
    @State private var diffCounts = CompareDiffCounts.zero
    @State private var diffCountsTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Compare")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(left.displayName)  ↔  \(right.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                diffLegend
                if isLargeCompare {
                    Text("Live compare paused")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: .editorModifiedAmber))
                }
                Spacer()
                Button {
                    documents.clearCompareMode()
                } label: {
                    Label("Exit Compare", systemImage: "xmark")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .bestTextPanelBackground))

            Divider()

            HStack(spacing: 0) {
                EditorRepresentable(document: left, comparePeer: right, compareSide: .left)
                    .id("compare-left-\(left.id)")
                Divider()
                EditorRepresentable(document: right, comparePeer: left, compareSide: .right)
                    .id("compare-right-\(right.id)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            refreshDiffCounts(leftText: left.text, rightText: right.text)
        }
        // NOT `.onChange(of: left.text)` / `.onChange(of: right.text)`.
        //
        // Those did two costly things per keystroke, on the main thread: SwiftUI
        // compared the whole old and new strings to decide whether the value
        // changed (O(document) for a one-character edit), and reading `.text` in
        // the body registered an observation dependency, so this header — legend
        // chips, tab names, the whole HStack — was re-evaluated on every
        // character typed in either pane.
        //
        // `.compareDocumentsDidChange` is posted by the pane that changed, once
        // per settled edit (`scheduleCompareDisplay`'s debounce) and after a
        // block transfer, and it carries only a document id. That is exactly the
        // moment the counts can differ, and the panes have just rebuilt from the
        // same memoised rows, so `CompareDiffCounter.make` is a cache hit.
        // The post is already debounced by the pane, and the pane has just built
        // the rows for exactly this pair of texts, so this is a cache hit in
        // `CompareEngine.buildRows` — no second debounce needed here.
        .onReceive(NotificationCenter.default.publisher(for: .compareDocumentsDidChange)) { _ in
            guard !isLargeCompare else {
                diffCounts = .zero
                return
            }
            refreshDiffCounts(leftText: left.text, rightText: right.text)
        }
        .onDisappear {
            diffCountsTask?.cancel()
        }
    }

    private var isLargeCompare: Bool {
        left.isLargeFileModeActive || right.isLargeFileModeActive
    }

    private var diffLegend: some View {
        let counts = diffCounts
        return HStack(spacing: 8) {
            if counts.removed > 0 { legendChip(symbol: "−", label: "\(counts.removed)", color: Color(nsColor: .bestTextDanger)) }
            if counts.added   > 0 { legendChip(symbol: "+", label: "\(counts.added)",   color: Color(nsColor: .bestTextSuccess)) }
            if counts.changed > 0 { legendChip(symbol: "~", label: "\(counts.changed)", color: Color(nsColor: .editorModifiedAmber)) }
            if counts.moved   > 0 { legendChip(symbol: "↕", label: "\(counts.moved)",   color: Color(nsColor: .bestTextMoved)) }
        }
    }

    private func legendChip(symbol: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(symbol).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color)
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func refreshDiffCounts(leftText: String, rightText: String) {
        diffCountsTask?.cancel()
        guard !isLargeCompare else { diffCounts = .zero; return }
        diffCountsTask = Task {
            let counts = await Task.detached(priority: .utility) {
                CompareDiffCounter.make(leftText: leftText, rightText: rightText)
            }.value
            guard !Task.isCancelled else { return }
            diffCounts = counts
        }
    }
}

/// Pure background-safe counter used by the compare header. Keeping this
/// outside the MainActor-isolated SwiftUI view is load-bearing: Swift 6 inserts
/// an executor precondition when a view-isolated static method is called from
/// the utility queue, which previously crashed as soon as compare mode opened.
nonisolated enum CompareDiffCounter {
    static func make(leftText: String, rightText: String) -> CompareDiffCounts {
        // Same rows the panes render. The header used to ask for `.liveEdit`
        // unconditionally while the panes started in `.detailed`, so on first
        // open of a 600-line compare the legend said "400 changed" over panes
        // showing "1 added / 1 removed". There is only one mode now.
        var r = 0; var a = 0; var c = 0; var m = 0
        for row in CompareEngine.buildRows(leftText: leftText, rightText: rightText) {
            switch row.kind {
            case .leftOnly:  r += 1
            case .rightOnly: a += 1
            case .changed:   c += 1
            // A moved line occupies one row on each pane (the peer's is a
            // filler), so count the pairs, not the rows — one line moved is
            // one move.
            case .moved:     if row.leftLineNumber != nil { m += 1 }
            case .paired:    r += 1; a += 1
            case .same:      break
            }
        }
        return CompareDiffCounts(removed: r, added: a, changed: c, moved: m)
    }
}

nonisolated struct CompareDiffCounts: Equatable, Sendable {
    static let zero = CompareDiffCounts(removed: 0, added: 0, changed: 0, moved: 0)
    var removed: Int
    var added: Int
    var changed: Int
    var moved: Int
}

nonisolated private enum ComparePaneSide: Sendable {
    case left
    case right
}

nonisolated private struct CompareRow: Sendable {
    enum Kind: Sendable { case same, changed, leftOnly, rightOnly, moved, paired }
    let leftLineNumber: Int?
    let leftText: String?
    let rightLineNumber: Int?
    let rightText: String?
    let kind: Kind
    /// For a `.moved` row: the peer side's line number for the same content.
    ///
    /// A moved row is one-sided — it carries text for exactly the side the line
    /// lives on and reads as a filler on the other. `detectMovedRows` used to
    /// lift the peer's row out of its position and fuse the two into a
    /// two-sided row, which made `realLineNumber` non-monotonic inside a diff
    /// block and broke the arithmetic every block transfer depends on.
    var movedCounterpartLine: Int? = nil
}

/// One row of built display text: its full range (content plus the trailing
/// "\n" the builder always appends) and the length of the visible content.
///
/// `contentLength` excludes a trailing CR, which a CRLF document's raw lines
/// still carry — a word highlight reaching the end of the line used to paint
/// over it because the clamp assumed a one-unit separator.
nonisolated private struct CompareRowRange: Sendable {
    let range: NSRange
    let contentLength: Int
}

/// One pane's built display: the text, the per-row gutter infos, and the row
/// ranges that index the text.
///
/// The ranges are the builder's own arithmetic. Everything downstream used to
/// re-derive them by walking `NSString.paragraphRange`, which breaks on a lone
/// CR and on U+2029 while `LineHashing.splitLines` does not — so from the first
/// stray CR onward every filler attribute, highlight range and gutter row was
/// off by one, and `realText(from:)` fed the wrong lines back into the document.
nonisolated private struct CompareDisplay: Sendable {
    let displayText: String
    let lineInfos: [CompareLineInfo]
    let rowRanges: [CompareRowRange]
}

nonisolated private final class CompareApplyGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func begin() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    func isCurrent(_ candidate: Int) -> Bool {
        lock.withLock { value == candidate }
    }
}

nonisolated private struct CompareLayoutSnapshot: Sendable {
    let displayText: String
    let lineInfos: [CompareLineInfo]
    let rowRanges: [NSRange]
    let wordHighlightRanges: [NSRange]
}

/// Line boundaries of a compare display, split on LF (0x0A) **only** — exactly
/// the boundary `CompareDisplayBuilder` joins its rows with.
///
/// Everything that walks the live storage (which the user can type into between
/// two builds, so the builder's row ranges no longer describe it) goes through
/// here instead of `NSString.paragraphRange`. paragraphRange breaks on a lone
/// CR, U+2029 and friends, none of which `LineHashing.splitLines` treats as a
/// line break, and it costs one ObjC round trip per line on the main thread.
/// Whether a finished compare rebuild may still be written to the storage.
nonisolated enum CompareApplyGuard {
    /// A rebuild is built from a snapshot of the document taken before it was
    /// dispatched off the main thread. If the user typed while it was in flight,
    /// the snapshot no longer describes the document, and writing it back
    /// rewrites the storage without the characters they just typed — silently,
    /// because `isApplyingCompare` suppresses `textDidChange` and the apply then
    /// calls `discardUndoHistory()`.
    static func shouldApply(builtFrom snapshot: String, documentText current: String) -> Bool {
        snapshot == current
    }
}

/// The arithmetic a block transfer turns a run of display rows into.
///
/// Kept out of the Coordinator so both the transfer and its tests use one copy.
nonisolated enum CompareTransferGeometry {

    /// `(replaceStart, replaceCount)` — 0-based, in the receiving document's own
    /// lines — or nil when the block must not be transferred.
    ///
    /// The block's real line numbers have to be a strictly increasing contiguous
    /// run, because only then does `first ... last` describe exactly the lines the
    /// user clicked on. A gap ([2, 100]) would replace 99 lines with two, and a
    /// descending run (which `detectMovedRows` used to produce by reordering rows)
    /// gave `replaceCount == 0`, so the splice inserted the block instead of
    /// replacing it, or went negative and did nothing at all. Refusing is the
    /// only safe answer for a shape whose meaning is undefined.
    static func replaceRange(infos: [CompareLineInfo], displayRows: NSRange) -> (start: Int, count: Int)? {
        guard displayRows.location >= 0, NSMaxRange(displayRows) <= infos.count else { return nil }
        let realLines = (displayRows.location ..< NSMaxRange(displayRows))
            .compactMap { infos[$0].realLineNumber }

        guard let first = realLines.first, let last = realLines.last else {
            // All filler on this side: the lines exist only on the other pane, so
            // this is a pure insertion after the nearest real line above.
            var anchor = 0
            var idx = displayRows.location - 1
            while idx >= 0 {
                if let real = infos[idx].realLineNumber { anchor = real; break }
                idx -= 1
            }
            return (anchor, 0)
        }
        // `first <= last` before the range is formed: a descending run is exactly
        // the shape being rejected, and `first...last` would trap on it.
        guard first >= 1, first <= last, realLines == Array(first...last) else { return nil }
        return (first - 1, last - first + 1)
    }
}

nonisolated enum CompareDisplayLines {
    private static let chunkSize = 4096

    /// Calls `body` once per line, with the line's full range including its
    /// trailing "\n" when it has one. Return false from `body` to stop.
    static func forEachLine(in ns: NSString, _ body: (NSRange) -> Bool) {
        let length = ns.length
        guard length > 0 else { return }
        var buffer = [unichar](repeating: 0, count: min(length, chunkSize))
        var lineStart = 0
        var pos = 0
        var stopped = false
        while pos < length && !stopped {
            let count = min(chunkSize, length - pos)
            ns.getCharacters(&buffer, range: NSRange(location: pos, length: count))
            var i = 0
            while i < count {
                if buffer[i] == 0x0A {
                    let end = pos + i + 1
                    if !body(NSRange(location: lineStart, length: end - lineStart)) {
                        stopped = true
                        break
                    }
                    lineStart = end
                }
                i += 1
            }
            pos += count
        }
        if !stopped && lineStart < length {
            _ = body(NSRange(location: lineStart, length: length - lineStart))
        }
    }

    /// Calls `body` once per line with the line's full range and whether the
    /// line is a compare filler — judged, as everywhere else, by the
    /// `.isFillerLine` attribute on its FIRST character.
    ///
    /// The attribute runs are collected in one `enumerateAttribute` pass rather
    /// than asked for per line: a 1500-line display otherwise costs 1500 ObjC
    /// attribute lookups on the main actor for every character typed, and there
    /// are only ever a handful of runs.
    static func forEachLine(in storage: NSTextStorage, _ body: (NSRange, Bool) -> Bool) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        var runs: [NSRange] = []
        storage.enumerateAttribute(.isFillerLine, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            if value != nil { runs.append(range) }
        }
        var cursor = 0
        forEachLine(in: ns) { lineRange in
            while cursor < runs.count, NSMaxRange(runs[cursor]) <= lineRange.location { cursor += 1 }
            let isFiller = cursor < runs.count && runs[cursor].location <= lineRange.location
            return body(lineRange, isFiller)
        }
    }
}

nonisolated private enum SavedLineMarkStyle: Sendable {
    case added
    case modified
    /// Lines were deleted here and nothing replaced them. There is no row left
    /// to mark, so the mark goes on the line the deletion closed up onto — the
    /// join line — in the same red the gutter already uses for a deleted line in
    /// compare mode. Without this a pure deletion was invisible: the file was
    /// modified since its last save and the gutter said nothing (U25).
    case deleted
}

nonisolated private enum CompareEngine {

    /// `buildRows` is a pure function of (leftText, rightText), and every
    /// keystroke in compare mode asks for the same answer three times: once per
    /// pane to rebuild the display, and once more for the header's diff counts.
    /// Memoising the last result lets those three share a single diff.
    ///
    /// `displayCache` does the same one level up: both panes' display text is
    /// built from the same rows, and the word-level diff inside it is a single
    /// symmetric computation whose two halves are the two panes' highlights.
    /// Building them together and memoising the pair halves that work.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (left: String, right: String, rows: [CompareRow])?
    nonisolated(unsafe) private static var displayCache: (left: String, right: String, panes: (left: CompareDisplay, right: CompareDisplay))?

    /// Called when a pane leaves compare mode so two whole documents are not
    /// held alive by the cache.
    static func clearCache() {
        cacheLock.lock()
        cache = nil
        displayCache = nil
        cacheLock.unlock()
    }

    static func buildRows(leftText: String, rightText: String) -> [CompareRow] {
        cacheLock.lock()
        let hit = cache
        cacheLock.unlock()
        if let hit, hit.left == leftText, hit.right == rightText {
            return hit.rows
        }

        let rows = computeRows(leftText: leftText, rightText: rightText)

        cacheLock.lock()
        cache = (leftText, rightText, rows)
        cacheLock.unlock()
        return rows
    }

    /// One pane's built display. The peer pane's build is computed at the same
    /// time and memoised, so the second pane's rebuild is a cache hit.
    static func display(leftText: String, rightText: String, side: ComparePaneSide) -> CompareDisplay {
        cacheLock.lock()
        let hit = displayCache
        cacheLock.unlock()
        if let hit, hit.left == leftText, hit.right == rightText {
            return side == .left ? hit.panes.left : hit.panes.right
        }

        let rows = buildRows(leftText: leftText, rightText: rightText)
        let panes = CompareDisplayBuilder.build(rows: rows)

        cacheLock.lock()
        displayCache = (leftText, rightText, panes)
        cacheLock.unlock()
        return side == .left ? panes.left : panes.right
    }

    private static func computeRows(leftText: String, rightText: String) -> [CompareRow] {
        var opts = CompareOptions()
        opts.ignoreCase = false
        opts.ignoreChangedSpaces = false
        // changedResemblPercent uses CompareOptions default (50 %)

        // Must use the same splitter as LineHashing.extractLines, or the line
        // numbers coming back from TextComparator index a different array.
        let linesA = LineHashing.splitLines(leftText)
        let linesB = LineHashing.splitLines(rightText)

        switch TextComparator.compare(rawLinesA: linesA, rawLinesB: linesB, options: opts) {
        case .match:
            return zip(linesA.indices, linesB.indices).map { ai, bi in
                CompareRow(
                    leftLineNumber: ai + 1,
                    leftText: linesA[ai],
                    rightLineNumber: bi + 1,
                    rightText: linesB[bi],
                    kind: .same
                )
            }

        case .cancelled:
            return []

        case .mismatch(let summary):
            return rows(from: summary.blocks, linesA: linesA, linesB: linesB, options: opts)
        }
    }

    static func liveEditDelay(leftText: String, rightText: String) -> TimeInterval {
        let total = estimatedLineCount(leftText) + estimatedLineCount(rightText)
        switch total {
        case ..<200:   return 0.08
        case ..<1000:  return 0.15
        case ..<5000:  return 0.25
        default:       return 0.35
        }
    }

    private static func rows(
        from blocks: [CompareBlock],
        linesA: [String],
        linesB: [String],
        options: CompareOptions
    ) -> [CompareRow] {
        var out: [CompareRow] = []

        for block in blocks {
            switch block {
            case .match(let aRange, let bRange):
                let count = min(aRange.count, bRange.count)
                for delta in 0..<count {
                    let aLine = aRange.lowerBound + delta
                    let bLine = bRange.lowerBound + delta
                    out.append(
                        CompareRow(
                            leftLineNumber: aLine,
                            leftText: textAt(line: aLine, from: linesA),
                            rightLineNumber: bLine,
                            rightText: textAt(line: bLine, from: linesB),
                            // Always .same. Genuinely moved lines are detected separately by
                            // detectMovedRows (leftOnly content matching a rightOnly line);
                            // comparing the two line numbers here marked every post-insertion
                            // match as moved.
                            kind: .same
                        )
                    )
                }

            case .onlyInA(let aRange):
                for aLine in aRange {
                    out.append(
                        CompareRow(
                            leftLineNumber: aLine,
                            leftText: textAt(line: aLine, from: linesA),
                            rightLineNumber: nil,
                            rightText: nil,
                            kind: .leftOnly
                        )
                    )
                }

            case .onlyInB(let bRange):
                for bLine in bRange {
                    out.append(
                        CompareRow(
                            leftLineNumber: nil,
                            leftText: nil,
                            rightLineNumber: bLine,
                            rightText: textAt(line: bLine, from: linesB),
                            kind: .rightOnly
                        )
                    )
                }

            case .changed(let aLines, let bLines):
                if aLines.count == bLines.count {
                    // Equal counts: safe to pair by index (preserves original order).
                    for i in 0..<aLines.count {
                        let a = aLines[i], b = bLines[i]
                        out.append(CompareRow(
                            leftLineNumber: a.lineNumber, leftText: a.text,
                            rightLineNumber: b.lineNumber, rightText: b.text,
                            kind: .changed
                        ))
                    }
                } else {
                    // Unequal counts: pair by word-similarity so inserted/deleted
                    // lines don't cause wrong word-diff pairings.
                    out.append(contentsOf: pairChangedBlock(aLines: aLines, bLines: bLines))
                }
            }
        }
        return alignAdjacentBlocks(detectMovedRows(in: out, options: options))
    }

    private static func estimatedLineCount(_ text: String) -> Int {
        // Counting over utf8 rather than Characters: grapheme breaking the whole
        // document just to count newlines is expensive, and it also mis-counted
        // CRLF text, where "\r\n" is a single Character that never equals "\n"
        // — every CRLF file looked like one line and got the shortest debounce.
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    /// Pair consecutive leftOnly+rightOnly blocks so they sit side-by-side with
    /// blank fillers on the shorter side — same visual alignment as ComparePlus.
    /// Handles both leftOnly→rightOnly and rightOnly→leftOnly orderings, which
    /// the LCS backtracker can produce depending on the DP table values.
    private static func alignAdjacentBlocks(_ rows: [CompareRow]) -> [CompareRow] {
        var result: [CompareRow] = []
        var i = 0
        while i < rows.count {
            var lefts:  [CompareRow] = []
            var rights: [CompareRow] = []
            // Collect any contiguous mix of leftOnly/rightOnly rows regardless of order.
            while i < rows.count, rows[i].kind == .leftOnly || rows[i].kind == .rightOnly {
                if rows[i].kind == .leftOnly { lefts.append(rows[i]) }
                else { rights.append(rows[i]) }
                i += 1
            }

            if !lefts.isEmpty || !rights.isEmpty {
                let count = max(lefts.count, rights.count)
                for j in 0..<count {
                    let l: CompareRow? = j < lefts.count  ? lefts[j]  : nil
                    let r: CompareRow? = j < rights.count ? rights[j] : nil
                    let kind: CompareRow.Kind = (l != nil && r != nil) ? .paired
                                             : (l != nil ? .leftOnly : .rightOnly)
                    result.append(CompareRow(
                        leftLineNumber:  l?.leftLineNumber,  leftText:  l?.leftText,
                        rightLineNumber: r?.rightLineNumber, rightText: r?.rightText,
                        kind: kind
                    ))
                }
            } else if i < rows.count {
                result.append(rows[i])
                i += 1
            }
        }
        return result
    }

    private static func textAt(line: Int, from lines: [String]) -> String? {
        let idx = line - 1
        guard idx >= 0 && idx < lines.count else { return nil }
        return lines[idx]
    }


    /// A line plus its word-bag, tokenised once.
    ///
    /// The Dice similarity below is the equality predicate of an O(n·m) DP, so
    /// it is evaluated once per cell. Computing it from the raw strings meant
    /// lowercasing and splitting *both* lines and building a fresh frequency
    /// dictionary in every cell — five heap allocations per cell, n·m times.
    /// Tokenising once per line up front makes the per-cell cost a pointer-free
    /// walk over two sorted arrays.
    private struct DiceLine {
        let line: ChangedLine
        /// Word ids, sorted, duplicates kept — a multiset in array form.
        let wordIDs: [Int32]
    }

    /// Word-set Dice similarity (0–100). Splits on spaces, case-insensitive.
    /// Used to match related lines inside a `.changed` block when counts differ.
    private static func wordDiceSimilarity(_ a: DiceLine, _ b: DiceLine) -> Int {
        if a.line.text == b.line.text { return 100 }
        let total = a.wordIDs.count + b.wordIDs.count
        guard total > 0 else { return 100 }

        // Multiset intersection by merging two sorted id arrays — the same count
        // the old frequency-dictionary pass produced.
        var i = 0, j = 0, shared = 0
        while i < a.wordIDs.count && j < b.wordIDs.count {
            let x = a.wordIDs[i], y = b.wordIDs[j]
            if x == y { shared += 1; i += 1; j += 1 }
            else if x < y { i += 1 }
            else { j += 1 }
        }
        return Int(Double(shared * 2) / Double(total) * 100)
    }

    /// When a `.changed` block has unequal line counts on each side, pair lines
    /// by similarity (Dice ≥ 30 %) rather than by index. Completely unrelated
    /// inserted/deleted lines land as .rightOnly/.leftOnly instead of being
    /// word-diffed against the wrong counterpart.
    private static func pairChangedBlock(
        aLines: [ChangedLine],
        bLines: [ChangedLine]
    ) -> [CompareRow] {
        var wordIDs: [Substring: Int32] = [:]
        var nextID: Int32 = 0
        func tokenise(_ line: ChangedLine) -> DiceLine {
            var ids: [Int32] = []
            for word in line.text.lowercased().split(separator: " ") {
                if let id = wordIDs[word] {
                    ids.append(id)
                } else {
                    wordIDs[word] = nextID
                    ids.append(nextID)
                    nextID += 1
                }
            }
            ids.sort()
            return DiceLine(line: line, wordIDs: ids)
        }

        let ops = DiffCalc.diff(aLines.map(tokenise), bLines.map(tokenise)) { a, b in
            wordDiceSimilarity(a, b) >= 30
        }
        var rows: [CompareRow] = []
        var pendingA: [ChangedLine] = []
        var pendingB: [ChangedLine] = []

        func flushPending() {
            let count = max(pendingA.count, pendingB.count)
            for i in 0..<count {
                let a = i < pendingA.count ? pendingA[i] : nil
                let b = i < pendingB.count ? pendingB[i] : nil
                rows.append(CompareRow(
                    leftLineNumber:  a?.lineNumber, leftText:  a?.text,
                    rightLineNumber: b?.lineNumber, rightText: b?.text,
                    kind: a == nil ? .rightOnly : (b == nil ? .leftOnly : .paired)
                ))
            }
            pendingA.removeAll(); pendingB.removeAll()
        }

        for op in ops {
            switch op {
            case .match(let a, let b):
                flushPending()
                rows.append(CompareRow(
                    leftLineNumber:  a.line.lineNumber, leftText:  a.line.text,
                    rightLineNumber: b.line.lineNumber, rightText: b.line.text,
                    kind: .changed
                ))
            case .onlyInA(let a): pendingA.append(a.line)
            case .onlyInB(let b): pendingB.append(b.line)
            }
        }
        flushPending()
        return rows
    }

    /// A moved line has to be substantial enough to mean something. The key used
    /// to be the bare normalised text with no floor at all, so in a Cisco config
    /// — where `!`, `exit`, `}` and blank lines are everywhere — deleting a blank
    /// line at the top and adding one at the bottom was reported as a *move*
    /// across the whole file.
    private static let minMovedCharacters = 8
    private static let minMovedTokens = 2

    /// How far apart two rows may be and still be called the same moved line.
    /// Bounds both the cost and the noise: a match 4000 rows away is much more
    /// likely to be two lines that happen to read alike than one line that moved.
    private static let movedSearchWindow = 1_000

    private static func isMoveCandidate(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        if normalized.utf16.count >= minMovedCharacters { return true }
        var tokens = 0
        var inToken = false
        for unit in normalized.utf16 {
            let isSpace = unit == 0x20 || unit == 0x09
            if isSpace {
                inToken = false
            } else if !inToken {
                inToken = true
                tokens += 1
                if tokens >= minMovedTokens { return true }
            }
        }
        return false
    }

    /// Annotates a `leftOnly`/`rightOnly` pair whose normalised text is identical
    /// as `.moved`, **in place**.
    ///
    /// This used to lift the right-hand row out of its position, fuse it into the
    /// left-hand row and drop the original. That broke the invariant every block
    /// transfer is built on: `realLineNumber` has to be a monotonic, contiguous
    /// run inside a diff block, because `applyCompareBlockTransfer` turns the
    /// block's first and last real line into a replace range. With left
    /// `X Y Z common` against right `Z Y X common` the right pane's line numbers
    /// came back 3, 2, 1, 4, and the arrow either duplicated the block
    /// (`replaceCount == 0`, so the splice inserted) or silently did nothing
    /// (a negative count). Each row now stays where the diff put it and carries
    /// only the peer's line number as an annotation.
    private static func detectMovedRows(in rows: [CompareRow], options: CompareOptions) -> [CompareRow] {
        var rightBuckets: [String: [Int]] = [:]
        for (idx, row) in rows.enumerated() where row.kind == .rightOnly {
            guard let text = row.rightText else { continue }
            let key = normalizeForMove(text, options: options)
            guard isMoveCandidate(key) else { continue }
            rightBuckets[key, default: []].append(idx)
        }
        guard !rightBuckets.isEmpty else { return rows }

        var result = rows
        var consumedRight = Set<Int>()

        // Per-key cursor rather than trimming the bucket in place: pulling the
        // array out of the dictionary with `var` forces a copy-on-write copy,
        // and writing it back copies again, so a file with many identical lines
        // (configs are full of them) made this quadratic in the bucket size.
        var bucketCursor: [String: Int] = [:]

        for (idx, row) in rows.enumerated() {
            guard row.kind == .leftOnly, let leftText = row.leftText else { continue }
            let key = normalizeForMove(leftText, options: options)
            guard isMoveCandidate(key), let candidates = rightBuckets[key] else { continue }

            var k = bucketCursor[key] ?? 0
            while k < candidates.count,
                  consumedRight.contains(candidates[k]) || candidates[k] < idx - movedSearchWindow {
                k += 1
            }
            bucketCursor[key] = k
            guard k < candidates.count, candidates[k] <= idx + movedSearchWindow else { continue }

            let matchIdx = candidates[k]
            consumedRight.insert(matchIdx)
            result[idx] = CompareRow(
                leftLineNumber: row.leftLineNumber,
                leftText: row.leftText,
                rightLineNumber: nil,
                rightText: nil,
                kind: .moved,
                movedCounterpartLine: rows[matchIdx].rightLineNumber
            )
            result[matchIdx] = CompareRow(
                leftLineNumber: nil,
                leftText: nil,
                rightLineNumber: rows[matchIdx].rightLineNumber,
                rightText: rows[matchIdx].rightText,
                kind: .moved,
                movedCounterpartLine: row.leftLineNumber
            )
        }

        return result
    }

    private static func normalizeForMove(_ text: String, options: CompareOptions) -> String {
        LineHashing.normalize(text, options: options)
    }
}

// Navigation/replace events posted by the find bar, consumed by the
// EditorRepresentable coordinator below.
extension Notification.Name {
    static let findBarNavigate      = Notification.Name("sheeptext.findBar.navigate")
    static let findBarReplace       = Notification.Name("sheeptext.findBar.replace")
    static let findBarReplaceAll    = Notification.Name("sheeptext.findBar.replaceAll")
    static let findBarHighlightAll  = Notification.Name("sheeptext.findBar.highlightAll")
    static let findBarClearHighlights = Notification.Name("sheeptext.findBar.clearHighlights")
}

private struct EditorRepresentable: NSViewRepresentable {

    @Environment(CursorState.self) private var cursor
    @Environment(DocumentStore.self) private var documents
    @Environment(AppPreferences.self) private var preferences
    let document: Document
    var comparePeer: Document? = nil
    var compareSide: ComparePaneSide? = nil
    
    func makeNSView(context: Context) -> NSView {
        // Manual TextKit 1 stack — NSLayoutManager is required by the
        // line-number gutter and the current-line highlight in EditorTextView.
        // NSTextView.scrollableTextView() creates TextKit 2 on macOS 15+,
        // which returns nil for layoutManager, breaking both features.
        let textStorage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalRuler = false
        scroll.hasHorizontalRuler = false
        scroll.rulersVisible = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = EditorTextView(frame: .zero, textContainer: textContainer)
        textView.document = document
        textView.preferences = preferences
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        // Prose autocorrections that have no business in source code.
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        // Smart insert/delete pads pasted text with spaces to make prose read
        // well; in code it silently changes what was pasted.
        textView.smartInsertDeleteEnabled = false
        textView.font = preferences.editorFont()
        textView.textColor = textView.editorForegroundColor
        textView.drawsBackground = true
        textView.backgroundColor = .editorBackground
        textView.insertionPointColor = textView.editorForegroundColor
        textView.typingAttributes = textView.editorBaseAttributes()
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true

        textView.string = document.text
        context.coordinator.noteStorageReplaced(syncedRevision: document.revision)
        textView.delegate = context.coordinator
        scroll.documentView = textView
        textView.applyDocumentVisualSettings()

        // Re-apply any folds saved for this document from a previous tab/view instance.
        // Never in a compare pane: applyCompareDisplay replaces the storage with
        // filler-aligned display text, so the restored placeholders are wiped while the
        // fold regions describing them stay behind. Those stale regions then feed
        // deinit's saveFolds/unfoldAll and overwrite the document's real saved folds.
        if comparePeer == nil, !document.isLargeFileModeActive, let storage = textView.textStorage {
            context.coordinator.foldingManager.restoreFolds(for: document.id.uuidString, in: storage)
        }

        // Gutter sits to the left of the scroll view. Using a plain NSView
        // container (without translatesAutoresizingMaskIntoConstraints = false)
        // lets SwiftUI set the container's frame while the children use Auto
        // Layout to fill it correctly.
        textView.foldingManager = context.coordinator.foldingManager
        layoutManager.ownerTextView = textView

        let gutter = LineNumberRulerView(scrollView: scroll, textView: textView)
        gutter.foldingManager = context.coordinator.foldingManager
        gutter.isHidden = !preferences.showsLineNumbers
        gutter.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(gutter)
        container.addSubview(scroll)

        let gutterWidthConstraint = gutter.widthAnchor.constraint(
            equalToConstant: preferences.showsLineNumbers ? gutter.preferredWidth() : 0
        )

        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutterWidthConstraint,

            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.boundGutter    = gutter
        context.coordinator.gutterWidthConstraint = gutterWidthConstraint
        // Lets the gutter widen itself once the line numbers need more digits.
        gutter.widthConstraint = gutterWidthConstraint
        context.coordinator.boundScrollView = scroll
        context.coordinator.documentStore  = documents
        context.coordinator.updateCompareContext(peer: comparePeer, side: compareSide)
        context.coordinator.startObserving(textView: textView, cursor: cursor)
        if !context.coordinator.applyPreparedHighlightIfAvailable(to: textView, document: document) {
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak textView] in
                guard let coordinator, let textView else { return }
                coordinator.applyCachedHighlightOrDefer(to: textView, document: document)
            }
        }

        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let textView = context.coordinator.boundTextView as? EditorTextView else { return }
        textView.preferences = preferences
        // preferredWidth(), not the base constant: this runs on every SwiftUI
        // update, and pinning it back to 44 here fought the gutter's own sizing
        // and made it jitter on every keystroke.
        context.coordinator.gutterWidthConstraint?.constant = preferences.showsLineNumbers
            ? (context.coordinator.boundGutter?.preferredWidth() ?? LineNumberRulerView.gutterWidth)
            : 0
        context.coordinator.boundGutter?.isHidden = !preferences.showsLineNumbers
        let compareContextChanged = context.coordinator.updateCompareContext(peer: comparePeer, side: compareSide)
        if textView.document?.id != document.id {
            let fm = context.coordinator.foldingManager
            if let storage = textView.textStorage {
                // Save outgoing document's folds, then expand them.
                if let prevID = textView.document?.id {
                    fm.saveFolds(for: prevID.uuidString)
                }
                fm.unfoldAll(in: storage)
            }
            context.coordinator.document = document
            textView.document = document
            // One text view serves every tab: without this, ⌘Z right after a tab
            // switch replayed the previous document's edit into this one.
            textView.discardUndoHistory()
            textView.string = document.text
            context.coordinator.noteStorageReplaced(syncedRevision: document.revision)
            textView.applyDocumentVisualSettings()
            context.coordinator.refresh(textView: textView, cursor: cursor)
            context.coordinator.applyCachedHighlightOrDefer(to: textView, document: document)
            // Restore incoming document's folds (if any).
            if !document.isLargeFileModeActive, let storage = textView.textStorage {
                fm.restoreFolds(for: document.id.uuidString, in: storage)
            }
        } else if compareContextChanged {
            textView.applyDocumentVisualSettings()
            context.coordinator.applyHighlight(to: textView, document: document)
        } else {
            // In compare mode skip both applyDocumentVisualSettings and applyHighlight on
            // every-keystroke SwiftUI re-renders. applyDocumentVisualSettings writes
            // .paragraphStyle over the entire storage each call (full re-layout); applyHighlight
            // would bypass the debounced scheduleCompareDisplay path. Both were already applied
            // on compareContextChanged, so skipping them here is safe.
            if context.coordinator.comparePeer == nil {
                // While typing, the NSTextView is already authoritative and textDidChange
                // schedules the lightweight/debounced highlight pass. Reapplying full visual
                // settings here causes a visible current-line flash near the first columns.
                //
                // Compare against the RECONSTRUCTED text, not textView.string: with a fold
                // open the view's string is the display text, shorter than document.text by
                // every folded block, so a plain comparison always reported a mismatch and
                // pushed the unfolded text straight back into the view. The fold vanished
                // from the screen while its region stayed in the manager, and the next
                // fullText(from:) then spliced that block into a document that already
                // contained it — the folded block ended up duplicated in the file.
                //
                // Cheap proof first (U19). Reconstructing the full text is an
                // allocation the size of the document and the comparison walks
                // both strings — on EVERY SwiftUI update, which in practice
                // means every keystroke, every selection change and every
                // window resize. `Document.revision` moves on each assignment to
                // `document.text`, and `textDidChange` records it here the
                // moment the storage becomes the document; the length check
                // catches a storage mutation that never went through
                // `textDidChange` at all.
                let folding = context.coordinator.foldingManager
                let storage = textView.textStorage
                let storageLength = storage?.length ?? (textView.string as NSString).length
                let inSync = context.coordinator.storageIsInSyncWithDocument(storageLength: storageLength)
                let viewText = inSync
                    ? nil
                    : (storage.map { folding.fullText(from: $0) } ?? textView.string)
                if let viewText, viewText != document.text {
                    // The storage is about to be replaced wholesale, so the regions
                    // describe text that no longer exists.
                    folding.discardRegions()
                    textView.discardUndoHistory()
                    textView.string = document.text
                    context.coordinator.noteStorageReplaced(syncedRevision: document.revision)
                    textView.applyDocumentVisualSettings()
                    context.coordinator.applyHighlight(to: textView, document: document)
                } else if viewText != nil {
                    // Equal after all: record it so the next update is O(1).
                    context.coordinator.noteStorageMatchesDocument()
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: Document
        let foldingManager = FoldingManager()
        private var observer: NSObjectProtocol?
        private var findNavigateObserver: NSObjectProtocol?
        private var findReplaceObserver:  NSObjectProtocol?
        private var findReplaceAllObserver: NSObjectProtocol?
        private var findHighlightObserver: NSObjectProtocol?
        private var findClearObserver: NSObjectProtocol?
        private var syntaxHighlightSettingsObserver: NSObjectProtocol?
        private var editorAppearanceObserver: NSObjectProtocol?
        private var appActivationObserver: NSObjectProtocol?
        private var systemWakeObserver: NSObjectProtocol?
        private var compareRefreshObserver: NSObjectProtocol?
        private var scrollFrameObserver: NSObjectProtocol?
        private var compareTransferObserver: NSObjectProtocol?
        private var documentReloadObserver: NSObjectProtocol?
        private var documentSaveObserver: NSObjectProtocol?
        // Not `private`: the DEBUG audit seam binds one directly, without the
        // global notification observers `startObserving` installs.
        weak var cursorState: CursorState?
        weak var boundTextView: NSTextView?
        weak var boundGutter: LineNumberRulerView?
        weak var boundScrollView: NSScrollView?
        var gutterWidthConstraint: NSLayoutConstraint?
        weak var documentStore: DocumentStore?
        weak var comparePeer: Document?
        var compareSide: ComparePaneSide?
        private var isSyncScrolling = false
        private var scrollBoundsObserver: NSObjectProtocol?
        private var scrollSyncObserver: NSObjectProtocol?
        var isApplyingCompare = false
        private var currentLineInfos: [CompareLineInfo] = []
        private var lastComparePeerID: Document.ID?
        private var lastCompareSide: ComparePaneSide?
        private var lastCompareLeftText: String?
        private var lastCompareRightText: String?
        private var lastAppliedCompareSide: ComparePaneSide?
        /// Sendable cancellation/generation state shared with background diff jobs.
        private let compareApplyGeneration = CompareApplyGeneration()
        private var editedLines: Set<Int> = []

        // MARK: Line-number memo (U23 / T7)
        //
        // `TextLineIndex.lineAndStart` is O(offset). It runs on every selection
        // change and, in compare mode, once more per keystroke — with the caret
        // near the end of a 5 MB file that is 4.6 ms of newline counting each
        // time, for an answer that moved by one character. The cursor memoises
        // the last position and scans only the delta.
        //
        // The stamp has to change whenever the text does, or the memo answers
        // for text that no longer exists. `editGeneration` covers same-length
        // edits (typing over a selection), the length covers any storage
        // mutation that skipped `textDidChange` — the two together, never one.
        private var lineCursor = TextLineIndex.Cursor()
        private var editGeneration = 0

        private func lineCursorStamp(_ length: Int) -> Int {
            editGeneration &* 31 &+ length
        }

        /// The storage was replaced from outside `textDidChange` (tab switch,
        /// reload from disk, compare rebuild, block transfer).
        ///
        /// `syncedRevision` is `document.revision` when the storage is known to
        /// hold exactly `document.text`, and nil when that cannot be claimed —
        /// a compare pane holds filler-padded display text, not the document.
        func noteStorageReplaced(syncedRevision: Int?) {
            editGeneration &+= 1
            lineCursor.invalidate()
            lastSyncedRevision = syncedRevision
            // The runs described the text that was there a moment ago. Painting
            // them over the new text would put the previous document's colours
            // on this one for as long as it takes the cache lookup (a tab
            // switch) or the engine (a reload) to answer.
            highlightRuns = []
            runsGeneration &+= 1
            paintedDisplayRange = nil
            paintedRunsGeneration = -1
            storageNeedsThaiSweep = true
        }

        /// The storage was found to already hold `document.text` (the slow
        /// comparison agreed): record it, without disturbing the highlight or
        /// the line memo, which are still valid.
        func noteStorageMatchesDocument() {
            lastSyncedRevision = document.revision
        }

        /// `document.revision` as of the last time the storage was known to hold
        /// `document.text`. Read by `updateNSView` to skip reconstructing the
        /// full text and comparing two whole documents on every SwiftUI update.
        private(set) var lastSyncedRevision: Int?

        /// The appearance the highlights in the storage were computed under.
        /// `nil` until the first apply. See S8/U17.
        var lastHighlightIsDark: Bool?

        // MARK: Highlight runs and the painted viewport
        //
        // `highlightRuns` describes the WHOLE document, in full-text UTF-16
        // offsets. Nothing of it is written into the text storage: the visible
        // slice is painted as temporary attributes on the layout manager, so
        // apply costs what the screen costs, not what the file costs.
        //
        // Three pieces of state and one rule each:
        //  - `runsGeneration` moves whenever the runs or the palette change.
        //    A paint whose generation is behind clears everything it painted and
        //    starts again; a paint at the same generation only fills in the part
        //    of the viewport it has not painted yet.
        //  - `paintedDisplayRange` is in DISPLAY offsets (what the storage
        //    holds), because that is what the layout manager indexes. A fold
        //    makes the two coordinate systems differ; `visibleSegments` maps
        //    between them.
        //  - `paintedIsDark` is the appearance the temporary attributes were
        //    resolved under.
        private(set) var highlightRuns: [HighlightRun] = []
        private var runsGeneration = 0
        private var paintedDisplayRange: NSRange?
        private var paintedRunsGeneration = -1
        private var paintedIsDark: Bool?
        /// Set when the storage is replaced wholesale: the Thai fallback font is
        /// a *storage* attribute (fonts change layout, so they can never be
        /// temporary) and has to be swept over the new text once. Ordinary
        /// typing is covered by `EditorTextView.didChangeText`, which sweeps the
        /// paragraph around the caret.
        private var storageNeedsThaiSweep = true

        #if DEBUG
        /// Counts `applyHighlight` calls, for the U17 regression test.
        static var applyHighlightCallCount = 0
        /// Counts viewport paints, and how many characters the last one covered
        /// — the "apply costs the screen, not the file" claim, asserted.
        static var viewportPaintCount = 0
        static var lastPaintedCharacterCount = 0
        #endif

        /// True when the storage is known to hold `document.text` and no work is
        /// needed to prove it: the document has not been reassigned since the
        /// last sync **and** the lengths still agree (a storage mutation that
        /// skipped `textDidChange` would show up here).
        func storageIsInSyncWithDocument(storageLength: Int) -> Bool {
            guard lastSyncedRevision == document.revision else { return false }
            // A collapsed fold shortens the storage by everything it hides,
            // minus the one placeholder character standing in for it.
            let hidden = foldingManager.regions.reduce(0) { $0 + $1.originalUTF16Length - 1 }
            return storageLength + hidden == document.textUTF16Count
        }

        private struct SyntaxHighlightCacheEntry {
            let language: String
            let utf16Length: Int
            let textHash: Int
            /// The engine's run list for this text — a few tens of bytes per
            /// token, where this used to be a document-sized
            /// `NSAttributedString` with its whole attribute-run store.
            ///
            /// No `isDark`: runs carry style ids, so one entry serves both
            /// appearances and a theme flip is a repaint, not a re-parse.
            let runs: [HighlightRun]
            /// The document this entry belongs to, held **weakly** so a closed
            /// tab's entry can be swept even if nothing tells the cache the tab
            /// is gone (S5).
            weak var document: Document?
        }

        private static var syntaxHighlightCache: [Document.ID: SyntaxHighlightCacheEntry] = [:]
        private static var syntaxHighlightCacheOrder: [Document.ID] = []
        /// Was 32 whole-document attributed strings, then 8. Runs are far
        /// smaller, but the number that matters is still "a handful of tabs",
        /// and it is deliberately the same as `SyntaxEngine.sessionLimit`, which
        /// keeps the same data one layer down.
        private static let syntaxHighlightCacheLimit = 8

        /// Drops a closed document's cached runs.
        ///
        /// Nothing else evicts it: `deinit` cannot (the coordinator is torn down
        /// on every tab switch, while the document stays open), and the LRU only
        /// evicts once 8 *other* documents have been highlighted. Call this from
        /// wherever a document stops existing — the same places that already call
        /// `SyntaxEngine.shared.discardSession(for:)`.
        static func discardSyntaxHighlight(for id: Document.ID) {
            storeSyntaxHighlight(nil, for: id)
        }

        #if DEBUG
        static var syntaxHighlightCacheLimitForTesting: Int { syntaxHighlightCacheLimit }
        static var syntaxHighlightCacheCountForTesting: Int { syntaxHighlightCache.count }
        static func syntaxHighlightCacheContainsForTesting(_ id: Document.ID) -> Bool {
            syntaxHighlightCache[id] != nil
        }
        static func clearSyntaxHighlightCacheForTesting() {
            syntaxHighlightCache.removeAll()
            syntaxHighlightCacheOrder.removeAll()
        }
        static func storeSyntaxHighlightForTesting(for document: Document) {
            storeSyntaxHighlight(
                SyntaxHighlightCacheEntry(
                    language: document.language,
                    utf16Length: document.textUTF16Count,
                    textHash: document.text.hashValue,
                    runs: [],
                    document: document
                ),
                for: document.id
            )
        }
        #endif

                init(document: Document) { self.document = document }

        isolated deinit {
            // A compare pane holds no folds (updateCompareContext dropped them and
            // makeNSView never restores any there). Saving from it would write an empty
            // set over the folds the normal-mode view saved on its way in.
            if comparePeer == nil, let storage = boundTextView?.textStorage {
                foldingManager.saveFolds(for: document.id.uuidString)
                // Keep editor storage canonical as this view tears down.
                foldingManager.unfoldAll(in: storage)
            }
            for obs in [observer, findNavigateObserver, findReplaceObserver, findReplaceAllObserver,
                        findHighlightObserver, findClearObserver,
                        syntaxHighlightSettingsObserver, editorAppearanceObserver, compareRefreshObserver,
                        compareTransferObserver,
                        documentReloadObserver, documentSaveObserver, scrollBoundsObserver,
                        scrollFrameObserver, scrollSyncObserver,
                        appActivationObserver] {
                if let obs { NotificationCenter.default.removeObserver(obs) }
            }
            if let obs = systemWakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
            }
        }

        /// This coordinator's text view, but only when it is the editor the find
        /// bar is currently acting on.
        ///
        /// The find-bar notifications are broadcasts (`object: nil`) carrying
        /// ranges computed against ONE editor's text. Compare mode keeps two
        /// coordinators alive at the same time, so unfiltered handlers applied
        /// those ranges to BOTH panes — a single Replace overwrote the same
        /// offsets in both files. `EditorCommandTarget` tracks the last editor to
        /// become first responder, which stays the right target even while the
        /// find field itself holds focus.
        private var focusedBoundTextView: NSTextView? {
            guard let textView = boundTextView else { return nil }
            // No editor has ever been registered (very early startup): act, rather
            // than silently dropping the user's Find.
            guard let focused = EditorCommandTarget.focusedEditor else { return textView }
            return focused === textView ? textView : nil
        }

        func startObserving(textView: NSTextView, cursor: CursorState) {
            self.cursorState   = cursor
            self.boundTextView = textView
            if let editor = textView as? EditorTextView {
                EditorCommandTarget.register(editor)
            }
            if let diffLayoutManager = textView.layoutManager as? DiffLayoutManager {
                diffLayoutManager.onCharactersEdited = { [weak self] range, delta in
                    self?.storageDidEditCharacters(newRange: range, delta: delta)
                }
                diffLayoutManager.onDidCompleteLayout = { [weak self] in
                    guard let self, let textView = self.boundTextView else { return }
                    self.paintVisibleHighlights(in: textView)
                }
            }

            observer = NotificationCenter.default.addMainActorObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                guard let self, let textView = self.boundTextView else { return }
                self.push(from: textView)
            }

            // Find-bar: scroll to a range and show the Xcode-style flash indicator.
            // We do NOT select the range — setSelectedRange would paint the system
            // blue selection on top of our yellow pill, hiding it entirely.
            findNavigateObserver = NotificationCenter.default.addMainActorObserver(
                forName: .findBarNavigate,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard
                    let self,
                    let tv = self.focusedBoundTextView,
                    let range = note.userInfo?["range"] as? NSRange
                else { return }
                tv.scrollRangeToVisible(range)
                tv.showFindIndicator(for: range)
            }

            // Find-bar: apply a replacement at a range, preserving undo.
            findReplaceObserver = NotificationCenter.default.addMainActorObserver(
                forName: .findBarReplace,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard
                    let self,
                    let tv = self.focusedBoundTextView,
                    let range = note.userInfo?["range"] as? NSRange,
                    let replacement = note.userInfo?["replacement"] as? String
                else { return }
                // Clear stale find highlights before the text-change fires applyHighlight.
                if let etv = tv as? EditorTextView { etv.findHighlightRanges = [] }
                guard NSMaxRange(range) <= (tv.textStorage?.length ?? 0) else { return }
                if tv.shouldChangeText(in: range, replacementString: replacement) {
                    tv.textStorage?.replaceCharacters(in: range, with: replacement)
                    // didChangeText() posts NSText.didChangeNotification, which AppKit
                    // forwards to this coordinator's textDidChange(_:). That is the one
                    // place that knows how to derive document.text correctly — through
                    // realText(from:) in compare mode and fullText(from:) when folds are
                    // present. Assigning tv.string here instead wrote filler lines (and
                    // fold placeholders) straight into the document, and into the file.
                    tv.didChangeText()
                }
            }

            // Find-bar: Replace All, as one edit and one undo step.
            findReplaceAllObserver = NotificationCenter.default.addMainActorObserver(
                forName: .findBarReplaceAll,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard
                    let self,
                    let editor = self.focusedBoundTextView as? EditorTextView,
                    let values = note.userInfo?["ranges"] as? [NSValue],
                    let replacement = note.userInfo?["replacement"] as? String
                else { return }
                editor.findHighlightRanges = []
                editor.replaceOccurrences(values.map(\.rangeValue), with: replacement)
            }

            // Find-bar: paint all match ranges yellow; amber for the current one.
            findHighlightObserver = NotificationCenter.default.addMainActorObserver(
                forName: .findBarHighlightAll,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let etv = self.focusedBoundTextView as? EditorTextView,
                      let ranges = note.userInfo?["ranges"] as? [NSRange]
                else { return }
                etv.findHighlightRanges = ranges
                etv.findCurrentIdx = note.userInfo?["currentIndex"] as? Int ?? 0
                etv.needsDisplay = true
            }

            // Find-bar: remove all find highlights when the bar closes or query clears.
            // Deliberately NOT filtered by focus: a pane that painted highlights while
            // it was focused must still be able to drop them once focus moves on.
            findClearObserver = NotificationCenter.default.addMainActorObserver(
                forName: .findBarClearHighlights,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let etv = self.boundTextView as? EditorTextView else { return }
                guard !etv.findHighlightRanges.isEmpty else { return }
                etv.findHighlightRanges = []
                etv.findCurrentIdx = 0
                etv.needsDisplay = true
            }

            syntaxHighlightSettingsObserver = NotificationCenter.default.addMainActorObserver(
                forName: .syntaxHighlightSettingsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Theme colours changed — cached highlight results are stale even
                // when `isDark` did not move, so this one forces.
                self?.invalidateHighlightingAfterExternalChange(force: true)
            }

            editorAppearanceObserver = NotificationCenter.default.addMainActorObserver(
                forName: .editorAppearanceDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.invalidateHighlightingAfterExternalChange(force: true)
            }

            // The system appearance can change silently while the app is backgrounded or
            // the Mac is asleep (e.g. auto light/dark switching by time of day). Without
            // these, stale highlight colors only get refreshed once the user switches tabs
            // and back, which happens to force a cache clear + reapply.
            appActivationObserver = NotificationCenter.default.addMainActorObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.invalidateHighlightingAfterExternalChange()
            }

            systemWakeObserver = NSWorkspace.shared.notificationCenter.addMainActorObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.invalidateHighlightingAfterExternalChange()
            }

            compareRefreshObserver = NotificationCenter.default.addMainActorObserver(
                forName: .compareDocumentsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, let tv = self.boundTextView as? EditorTextView, self.comparePeer != nil else { return }
                guard !self.isLargeCompareContext else { return }
                if let originID = notification.userInfo?["documentID"] as? Document.ID,
                   originID == self.document.id {
                    return
                }
                self.applyCompareDisplay(to: tv, document: self.document)
            }

            compareTransferObserver = NotificationCenter.default.addMainActorObserver(
                forName: .compareBlockTransfer,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, self.comparePeer != nil,
                      let info = notification.userInfo,
                      let targetID = info["targetDocumentID"] as? Document.ID,
                      targetID == self.document.id,
                      let rowValue = info["displayRows"] as? NSValue,
                      let lines = info["lines"] as? [String]
                else { return }
                self.applyCompareBlockTransfer(displayRows: rowValue.rangeValue, replacementLines: lines)
            }

            documentReloadObserver = NotificationCenter.default.addMainActorObserver(
                forName: .documentReloadedFromDisk,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let documentID = notification.userInfo?["documentID"] as? Document.ID,
                    documentID == self.document.id,
                    let textView = self.boundTextView as? EditorTextView
                else { return }

                if self.comparePeer != nil {
                    self.applyCompareDisplay(to: textView, document: self.document)
                    // A reload changes this pane's text without any keystroke, and
                    // the peer's display is built from BOTH texts — as are the
                    // header's counts, which now come off this notification (U20).
                    // Only this pane used to rebuild, leaving the other one showing
                    // a diff against text that no longer exists.
                    NotificationCenter.default.post(
                        name: .compareDocumentsDidChange,
                        object: nil,
                        userInfo: ["documentID": self.document.id]
                    )
                    return
                }

                // Same reason as in updateNSView: the storage is replaced wholesale, so
                // any fold region left behind would duplicate its block into document.text.
                self.foldingManager.discardRegions()
                textView.discardUndoHistory()
                textView.string = self.document.text
                self.noteStorageReplaced(syncedRevision: self.document.revision)
                textView.applyDocumentVisualSettings()
                if let cursor = self.cursorState {
                    self.refresh(textView: textView, cursor: cursor)
                }
                self.applyHighlight(to: textView, document: self.document)
            }

            documentSaveObserver = NotificationCenter.default.addMainActorObserver(
                forName: .documentDidSave,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let documentID = notification.userInfo?["documentID"] as? Document.ID,
                    documentID == self.document.id
                else { return }
                self.boundGutter?.savedLineMarks = [:]
                self.editedLines = []
                self.boundGutter?.editedLines = []
            }

            // Scroll sync between compare panes: observe our own scroll view's content
            // bounds and broadcast a normalized fraction; also listen for the peer's
            // fraction and apply it without triggering another broadcast.
            if let sv = boundScrollView {
                // Resizing the window changes what is on screen without moving
                // the scroll origin, so the paint has to follow the frame too.
                sv.contentView.postsFrameChangedNotifications = true
                scrollFrameObserver = NotificationCenter.default.addMainActorObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: sv.contentView,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, let textView = self.boundTextView else { return }
                    self.paintVisibleHighlights(in: textView)
                }

                scrollBoundsObserver = NotificationCenter.default.addMainActorObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: sv.contentView,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    // Paint the strip that just scrolled in, BEFORE the compare
                    // guard: this is the one notification that fires on every
                    // scroll, in both modes, and in compare mode it does nothing
                    // (compare panes are not syntax-highlighted).
                    if let textView = self.boundTextView {
                        self.paintVisibleHighlights(in: textView)
                    }
                    guard !self.isSyncScrolling, self.comparePeer != nil else { return }
                    guard let sv = self.boundScrollView else { return }
                    let docH = sv.documentView?.frame.height ?? 0
                    let visH = sv.contentSize.height
                    let maxScroll = docH - visH
                    guard maxScroll > 0 else { return }
                    let fraction = max(0, min(1, sv.documentVisibleRect.origin.y / maxScroll))
                    NotificationCenter.default.post(
                        name: .compareSyncScroll,
                        object: nil,
                        userInfo: ["fraction": fraction, "sourceID": self.document.id]
                    )
                }
            }

            scrollSyncObserver = NotificationCenter.default.addMainActorObserver(
                forName: .compareSyncScroll,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, self.comparePeer != nil else { return }
                guard let sourceID = notification.userInfo?["sourceID"] as? Document.ID,
                      sourceID != self.document.id else { return }
                guard let fraction = notification.userInfo?["fraction"] as? CGFloat,
                      let sv = self.boundScrollView else { return }
                self.isSyncScrolling = true
                defer { self.isSyncScrolling = false }
                let docH = sv.documentView?.frame.height ?? 0
                let visH = sv.contentSize.height
                let maxScroll = max(0, docH - visH)
                let targetY = fraction * maxScroll
                sv.documentView?.scroll(NSPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
            }

            // Kick an initial read so the status bar isn't empty.
            refresh(textView: textView, cursor: cursor)
        }

        @discardableResult
        func updateCompareContext(peer: Document?, side: ComparePaneSide?) -> Bool {
            let peerID = peer?.id
            let changed = peerID != lastComparePeerID || side != lastCompareSide
            // Only when this pane actually LEAVES compare mode. updateNSView calls
            // this on every SwiftUI re-render, so an unconditional clear threw the
            // memo away from any non-compare editor sharing the window with a
            // compare pane — i.e. every keystroke in the ordinary case.
            if peer == nil, changed, lastComparePeerID != nil { CompareEngine.clearCache() }
            if changed, peer != nil, !foldingManager.regions.isEmpty {
                // Switching into compare: the storage is about to be replaced by display
                // text, so these regions would describe characters that no longer exist.
                if let storage = boundTextView?.textStorage {
                    foldingManager.saveFolds(for: document.id.uuidString)
                    foldingManager.unfoldAll(in: storage)
                }
                foldingManager.discardRegions()
            }
            if changed {
                // Either the storage is about to become filler-padded display
                // text, or it is about to go back to being the document: nothing
                // recorded against the old shape survives (U19/U23).
                noteStorageReplaced(syncedRevision: nil)
                // Syntax colours are temporary attributes on the layout manager,
                // and compare mode paints its own (`.backgroundColor`) on the
                // same one over text that is not even the same text. Leaving
                // ours behind would tint filler lines with the colours of
                // whatever used to be at those offsets.
                if let textView = boundTextView {
                    dropHighlightRuns(clearingPaintIn: textView)
                }
            }
            comparePeer = peer
            compareSide = side
            lastComparePeerID = peerID
            lastCompareSide = side
            return changed
        }

        func refresh(textView: NSTextView, cursor: CursorState) {
            // NSString.length, exactly like `push` below (U8). This used to be
            // `String.count`, so the status bar's "N chars" meant grapheme
            // clusters right after a tab switch and UTF-16 units from the first
            // selection change onwards: "🐑🐑🐑" read 3, then 6. It was also an
            // O(document) grapheme-breaking pass on the main thread.
            let total = ((textView.textStorage?.string ?? textView.string) as NSString).length
            cursor.line          = 1
            cursor.column        = 1
            cursor.selectedCount = 0
            cursor.totalCount    = total
        }

        // Not `private`: the DEBUG audit seam at the bottom of this file drives
        // it directly so the status-bar counts can be tested without a window.
        func push(from textView: NSTextView) {
            guard let cursorState else { return }
            let str = (textView.textStorage?.string ?? textView.string) as NSString
            let totalCount = str.length
            let selected = textView.selectedRange()
            let loc = min(selected.location, totalCount)

            // Counts newlines in place instead of copying the whole prefix and
            // splitting it into per-line Strings, which this did on every
            // keystroke. Same numbers — the column is still a grapheme count —
            // but ~14x faster on a 3000-line file, and it allocates nothing.
            // (enumerateSubstrings is still not usable here: it fires for
            // partial lines and resets the column.)
            //
            // Through the memo (U23/T7): within one stamp this walks the delta
            // from the previous caret position instead of counting every newline
            // from offset 0 again. Same result as `TextLineIndex.lineColumn`,
            // which is what the column arithmetic below is copied from.
            let (line, lineStart) = lineCursor.lineAndStart(
                in: str, at: loc, stamp: lineCursorStamp(totalCount)
            )
            let linePrefix = str.substring(with: NSRange(location: lineStart, length: loc - lineStart))

            cursorState.line = line
            cursorState.column = linePrefix.count + 1
            cursorState.selectedCount = selected.length
            cursorState.totalCount = totalCount
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            guard !isApplyingCompare else { return }
            guard !foldingManager.isMutating else { return }
            guard let storage = tv.textStorage else { return }

            // The text changed, so every line-number memo taken against it is
            // stale. Bumped before `push` so the stamp it builds is the new one.
            editGeneration &+= 1

            if let editor = tv as? EditorTextView, comparePeer != nil {
                // Extract real (non-filler) text from the display storage.
                document.text = editor.realText(from: storage)
                document.precomputedSyntaxHighlight = nil
                document.isDirty = true
                scheduleSafetySaves(for: document, textView: tv)
                push(from: tv)

                // Record which display line was edited so the gutter can show *.
                let cursorLoc = tv.selectedRange().location
                let displayStr = storage.string as NSString
                let safeLoc = min(cursorLoc, displayStr.length)
                // Same memo as `push` (which ran a line above, over the same
                // string and the same caret): a cache hit, not a second scan.
                let editedLine = lineCursor.lineNumber(
                    in: displayStr, at: safeLoc, stamp: lineCursorStamp(displayStr.length)
                )
                editedLines.insert(editedLine)
                boundGutter?.editedLines = editedLines

                // A rebuild may be in flight, built from the text as it was BEFORE
                // this keystroke. It is stopped by the source-text check in
                // applyCompareDisplay's main-queue block, not from here: bumping
                // the generation counter here would also kill a job whose result
                // is still wanted (typing and immediately reverting inside one
                // debounce leaves the document reading exactly what the doomed
                // job was built from, and the early-return guard would then skip
                // the rebuild it needs).

                guard !isLargeCompareContext else { return }
                // Rebuild compare display after a short debounce.
                scheduleCompareDisplay(textView: editor, document: document)
                return
            }

            // Consume the flag BEFORE deciding anything: collapsing or expanding a fold
            // fires textDidChange, but fullText() reconstructs the very same document
            // text, so treating it as an edit marked a pristine file dirty (and kicked
            // off a draft/auto save) purely because the user folded a block.
            let isFoldMutation = foldingManager.consumeFoldMutationFlag()

            document.text = foldingManager.fullText(from: storage)
            // The storage IS the document now, and `revision` moved with that
            // assignment: `updateNSView` can skip rebuilding the full text and
            // comparing it against `document.text` until something else changes
            // the document (U19).
            lastSyncedRevision = document.revision
            document.precomputedSyntaxHighlight = nil
            if !isFoldMutation {
                document.isDirty = true
                scheduleSafetySaves(for: document, textView: tv)
            }
            push(from: tv)
            // (No compare notification here: the compare branch above returns, so
            // comparePeer is always nil by this point. The post that used to sit
            // here carried no documentID either, which would have rebuilt BOTH
            // panes instead of the peer's.)

            scheduleSavedLineMarks()

            if isFoldMutation {
                // The runs are unchanged (they describe the FULL text, which a
                // fold does not touch) but every display offset below the fold
                // has moved, so the paint has to be thrown away and redone.
                foldingDidChangeDisplayText(in: tv)
                return
            }

            // Runs were shifted by `storageDidEditCharacters` as the storage was
            // edited; repaint what is on screen from them right away rather than
            // waiting out the rehighlight debounce.
            paintVisibleHighlights(in: tv)
            // Invalidate any highlight already in flight. Its attributes were
            // computed from the text as it was before this edit, and the
            // incremental apply path only checked that the lengths matched — so
            // typing over a selection (same length) could paint stale colors
            // until the next debounce fired.
            highlightGeneration += 1
            scheduleRehighlight(textView: tv)
        }

        private func scheduleSafetySaves(for document: Document, textView: NSTextView) {
            documentStore?.scheduleDraftSave(for: document.id)
            let preferences = (textView as? EditorTextView)?.preferences
            documentStore?.scheduleAutoSave(
                for: document.id,
                isEnabled: preferences?.autoSaveEnabled ?? false,
                delay: preferences?.autoSaveDelay ?? 3
            )
        }

        /// Clears the syntax-highlight cache and reapplies highlighting/gutter state.
        /// Used whenever the system or in-app appearance may have changed underneath us
        /// (theme change, app reactivation, system wake) so stale `isDark`-keyed cache
        /// entries don't linger until the next tab switch forces a refresh.
        ///
        /// `force` is the difference between "something that can only be an
        /// appearance change happened" and "something that *might* have changed
        /// the appearance happened". Activation and wake are the second kind: the
        /// app is re-activated on every ⌘-Tab, and this body wipes a **static**
        /// cache shared by every coordinator, re-applies the visual settings and
        /// re-highlights the whole document. So those two pass no force and stop
        /// here when the resolved appearance is the one the paint was last
        /// resolved under. The apply itself is a viewport repaint now, but this
        /// still calls `applyDocumentVisualSettings`, which rewrites the base
        /// colour over the whole storage — that part is genuinely O(document)
        /// and is why the guard is still worth having. Theme and syntax-settings changes DO force:
        /// the token colours can change without `isDark` moving. (S8/U17)
        func invalidateHighlightingAfterExternalChange(force: Bool = false) {
            guard let tv = boundTextView as? EditorTextView else { return }
            let isDark = resolvedIsDark(for: tv)
            guard force || lastHighlightIsDark != isDark else { return }
            lastHighlightIsDark = isDark
            // The cache is NOT wiped here any more. It holds runs, and a run
            // carries a style id rather than a colour, so the same entry is
            // correct in either appearance — `applyHighlight` will hit it and
            // the repaint will resolve the new palette. Wiping it turned every
            // theme flip into a re-parse of every open document.
            tv.applyDocumentVisualSettings()
            lastCompareLeftText = nil
            lastCompareRightText = nil
            applyHighlight(to: tv, document: document)
            boundGutter?.needsDisplay = true
            let showsNums = tv.preferences?.showsLineNumbers == true
            gutterWidthConstraint?.constant = showsNums
                ? (boundGutter?.preferredWidth() ?? LineNumberRulerView.gutterWidth)
                : 0
            boundGutter?.isHidden = !showsNums
        }

        /// The appearance `SyntaxEngine` results are keyed on for this pane:
        /// the in-app theme preference when there is one, the effective system
        /// appearance otherwise.
        func resolvedIsDark(for textView: NSTextView) -> Bool {
            (textView as? EditorTextView)?.preferences?.isDarkHighlight(for: textView.effectiveAppearance)
                ?? (textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }

        /// Bring this pane's highlighting up to date: base colours, then runs
        /// for the whole document, then a paint of what is on screen.
        ///
        /// It no longer writes a single syntax attribute into the text storage.
        /// It used to `setAttributes` over the whole document and then walk the
        /// engine's attributed string with `enumerateAttributes` — 65 ms at 542k
        /// characters, on the main thread, on every tab switch, appearance
        /// change and dropped completion.
        func applyHighlight(to textView: NSTextView, document: Document) {
            if textView.hasMarkedText() {
                return
            }
            #if DEBUG
            Self.applyHighlightCallCount += 1
            #endif
            // Recorded even for a compare pane and for large-file mode, both of
            // which return before the highlight itself: the activation guard
            // asks "is this the appearance we last worked under", and the
            // answer for those panes is yes.
            lastHighlightIsDark = resolvedIsDark(for: textView)
            applyEditorBaseColors(to: textView)
            let baseAttributes = editorBaseAttributes(for: textView)
            textView.typingAttributes = baseAttributes

            // In compare mode, build filler-aligned display text and skip syntax highlighting.
            if let editor = textView as? EditorTextView, comparePeer != nil {
                dropHighlightRuns(clearingPaintIn: textView)
                applyCompareDisplay(to: editor, document: document)
                return
            }

            guard let storage = textView.textStorage else { return }
            sweepThaiFontIfStorageIsNew(textView)

            let displayLength = storage.length
            guard displayLength > 0 else { return }

            if document.isLargeFileModeActive {
                resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                return
            }

            let sourceText = foldingManager.fullText(from: storage)
            let resolvedLanguage = NetworkConfigLanguage.engineLanguage(
                for: HighlightOverrides.shared.resolvedLanguage(
                    for: document.url,
                    defaultLanguage: document.language
                ),
                vendor: document.networkVendor
            )
            let sourceLength = (sourceText as NSString).length
            let sourceHash = sourceText.hashValue

            guard SyntaxEngine.supportsHighlighting(resolvedLanguage) else {
                resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                Self.storeSyntaxHighlight(nil, for: document.id)
                return
            }

            if applyPreparedHighlightIfAvailable(
                to: textView,
                document: document,
                language: resolvedLanguage,
                sourceLength: sourceLength,
                sourceHash: sourceHash
            ) {
                return
            }

            highlightGeneration += 1
            let currentGeneration = highlightGeneration

            SyntaxEngine.shared.highlightRuns(
                text: sourceText,
                language: resolvedLanguage,
                documentID: document.id
            ) { [weak self, weak textView] result in
                guard let self else { return }
                guard
                    let textView,
                    self.highlightGeneration == currentGeneration,
                    self.boundTextView === textView,
                    let storage = textView.textStorage
                else { return }

                if let result {
                    Self.storeSyntaxHighlight(
                        SyntaxHighlightCacheEntry(
                            language: resolvedLanguage,
                            utf16Length: sourceLength,
                            textHash: sourceHash,
                            runs: result.runs,
                            document: document
                        ),
                        for: document.id
                    )
                    self.setHighlightRuns(result.runs, in: textView)
                } else {
                    Self.storeSyntaxHighlight(nil, for: document.id)
                    self.resetHighlightAttributes(
                        in: storage,
                        baseAttributes: self.editorBaseAttributes(for: textView)
                    )
                }
            }
        }

        func applyCachedHighlightOrDefer(to textView: NSTextView, document: Document) {
            deferredHighlightWorkItem?.cancel()
            applyEditorBaseColors(to: textView)

            let baseAttributes = editorBaseAttributes(for: textView)
            textView.typingAttributes = baseAttributes
            guard comparePeer == nil, let storage = textView.textStorage, storage.length > 0 else {
                applyHighlight(to: textView, document: document)
                return
            }
            sweepThaiFontIfStorageIsNew(textView)

            if document.isLargeFileModeActive {
                resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                return
            }

            let sourceText = foldingManager.fullText(from: storage)
            let resolvedLanguage = NetworkConfigLanguage.engineLanguage(
                for: HighlightOverrides.shared.resolvedLanguage(
                    for: document.url,
                    defaultLanguage: document.language
                ),
                vendor: document.networkVendor
            )

            if applyPreparedHighlightIfAvailable(
                to: textView,
                document: document,
                language: resolvedLanguage,
                sourceLength: (sourceText as NSString).length,
                sourceHash: sourceText.hashValue
            ) {
                return
            }

            applyVisibleHighlight(
                to: textView,
                document: document,
                storage: storage,
                language: resolvedLanguage
            )
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, self.document.id == document.id else { return }
                self.applyHighlight(to: textView, document: document)
            }
            deferredHighlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }

        @discardableResult
        func applyPreparedHighlightIfAvailable(to textView: NSTextView, document: Document) -> Bool {
            applyEditorBaseColors(to: textView)
            textView.typingAttributes = editorBaseAttributes(for: textView)
            guard comparePeer == nil,
                  !document.isLargeFileModeActive,
                  let storage = textView.textStorage,
                  storage.length > 0
            else { return false }
            sweepThaiFontIfStorageIsNew(textView)

            let sourceText = foldingManager.fullText(from: storage)
            let resolvedLanguage = NetworkConfigLanguage.engineLanguage(
                for: HighlightOverrides.shared.resolvedLanguage(
                    for: document.url,
                    defaultLanguage: document.language
                ),
                vendor: document.networkVendor
            )
            return applyPreparedHighlightIfAvailable(
                to: textView,
                document: document,
                language: resolvedLanguage,
                sourceLength: (sourceText as NSString).length,
                sourceHash: sourceText.hashValue
            )
        }

        /// Runs we already have for exactly this text — from the shared cache
        /// (tab switch) or from `DocumentStore`'s open-time precompute.
        ///
        /// Neither is keyed on the appearance any more: a run carries a style
        /// id, so the same list paints light or dark.
        private func applyPreparedHighlightIfAvailable(
            to textView: NSTextView,
            document: Document,
            language: String,
            sourceLength: Int,
            sourceHash: Int
        ) -> Bool {
            if let cached = Self.syntaxHighlightCache[document.id],
               cached.language == language,
               cached.utf16Length == sourceLength,
               cached.textHash == sourceHash {
                setHighlightRuns(cached.runs, in: textView)
                return true
            }

            if let precomputed = document.precomputedSyntaxHighlight,
               precomputed.language == language,
               precomputed.utf16Length == sourceLength,
               precomputed.textHash == sourceHash {
                Self.storeSyntaxHighlight(
                    SyntaxHighlightCacheEntry(
                        language: precomputed.language,
                        utf16Length: precomputed.utf16Length,
                        textHash: precomputed.textHash,
                        runs: precomputed.runs,
                        document: document
                    ),
                    for: document.id
                )
                document.precomputedSyntaxHighlight = nil
                setHighlightRuns(precomputed.runs, in: textView)
                return true
            }

            return false
        }

        /// First paint of a tab whose runs are not cached: highlight only the
        /// text on screen, as a standalone snippet, while the whole-file pass is
        /// still queued. The snippet's ranges are offset into full-text
        /// coordinates so the painter treats them like any other runs — but they
        /// are deliberately NOT cached: they describe a fragment, not the file.
        private func applyVisibleHighlight(
            to textView: NSTextView,
            document: Document,
            storage: NSTextStorage,
            language: String
        ) {
            guard SyntaxEngine.supportsHighlighting(language),
                  foldingManager.regions.isEmpty,
                  let range = visibleParagraphRange(in: textView),
                  range.location != NSNotFound,
                  range.length > 0,
                  NSMaxRange(range) <= storage.length
            else { return }

            let visibleText = (storage.string as NSString).substring(with: range)
            guard !visibleText.isEmpty else { return }
            let documentID = document.id
            SyntaxEngine.shared.snapshotRuns(
                text: visibleText,
                language: language
            ) { [weak self, weak textView] runs in
                guard let self,
                      let textView,
                      let storage = textView.textStorage,
                      self.document.id == documentID,
                      self.boundTextView === textView,
                      self.comparePeer == nil,
                      self.foldingManager.regions.isEmpty,
                      NSMaxRange(range) <= storage.length,
                      let runs
                else { return }

                self.setHighlightRuns(
                    runs.map {
                        HighlightRun(
                            location: $0.location + range.location,
                            length: $0.length,
                            style: $0.style
                        )
                    },
                    in: textView
                )
            }
        }

        // MARK: - Viewport painting

        /// The run list this pane paints from, and everything that depends on
        /// it, replaced in one step.
        func setHighlightRuns(_ runs: [HighlightRun], in textView: NSTextView) {
            highlightRuns = runs
            runsGeneration &+= 1
            paintVisibleHighlights(in: textView)
        }

        /// Forget the runs and scrub every temporary attribute this pane owns.
        func dropHighlightRuns(clearingPaintIn textView: NSTextView) {
            highlightRuns = []
            runsGeneration &+= 1
            clearPaintedAttributes(in: textView, range: nil)
            paintedDisplayRange = nil
            paintedRunsGeneration = runsGeneration
        }

        /// How much beyond the visible rect to paint, as a multiple of its
        /// height, above and below. One screen each way means an ordinary
        /// scroll — a swipe, a page down — lands on text that is already
        /// coloured, and only a long jump has to paint before it draws.
        private static let viewportMarginScreens: CGFloat = 1

        /// Paint the visible characters (plus the margin) from `highlightRuns`.
        ///
        /// Idempotent, and cheap to call: at the same generation it paints only
        /// the strip that scrolled into view.
        func paintVisibleHighlights(in textView: NSTextView) {
            guard comparePeer == nil,
                  !document.isLargeFileModeActive,
                  let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage,
                  storage.length > 0
            else { return }

            let isDark = resolvedIsDark(for: textView)
            let palette = HighlightPalette.shared(isDark: isDark)

            if paintedRunsGeneration != runsGeneration || paintedIsDark != isDark {
                // The runs or the colours moved: everything painted describes
                // the previous answer. Scrubbing the whole storage costs one
                // pass over the temporary-attribute runs we ourselves put there
                // — a few thousand entries at most, never the document.
                clearPaintedAttributes(in: textView, range: nil)
                paintedDisplayRange = nil
                paintedRunsGeneration = runsGeneration
                paintedIsDark = isDark
            }

            guard let target = viewportCharacterRange(in: textView) else { return }

            var pieces: [NSRange]
            if let painted = paintedDisplayRange {
                if NSIntersectionRange(painted, target) == target { return }
                pieces = Self.subtracting(painted, from: target)
            } else {
                pieces = [target]
            }
            guard !pieces.isEmpty else { return }

            let segments = visibleSegments(in: storage)
            let baseColor = (textView as? EditorTextView)?.editorForegroundColor ?? .editorForeground
            #if DEBUG
            Self.viewportPaintCount += 1
            Self.lastPaintedCharacterCount = pieces.reduce(0) { $0 + $1.length }
            #endif

            for piece in pieces {
                paint(
                    displayRange: piece,
                    segments: segments,
                    palette: palette,
                    baseColor: baseColor,
                    layoutManager: layoutManager,
                    storageLength: storage.length
                )
            }

            let union = paintedDisplayRange.map { NSUnionRange($0, target) } ?? target
            // Scrolling through a long file would otherwise leave the painted
            // window growing without bound, and the next generation change would
            // have to scrub all of it.
            if union.length > 4 * max(target.length, 1) {
                for stale in Self.subtracting(target, from: union) {
                    clearPaintedAttributes(in: textView, range: stale)
                }
                paintedDisplayRange = target
            } else {
                paintedDisplayRange = union
            }
        }

        private func paint(
            displayRange piece: NSRange,
            segments: [(full: NSRange, display: NSRange)],
            palette: HighlightPalette,
            baseColor: NSColor,
            layoutManager: NSLayoutManager,
            storageLength: Int
        ) {
            let piece = NSIntersectionRange(piece, NSRange(location: 0, length: storageLength))
            guard piece.length > 0 else { return }

            // Only the keys this pane owns (see
            // `HighlightStyleTable.ownedAttributeKeys`): compare mode's word
            // highlights are `.backgroundColor` temporary attributes on the same
            // layout manager, and removing a key we did not paint would erase
            // somebody else's work.
            layoutManager.removeTemporaryAttribute(.obliqueness, forCharacterRange: piece)
            layoutManager.removeTemporaryAttribute(.strokeWidth, forCharacterRange: piece)
            // One call covers every character with the editor's own colour; the
            // runs then overwrite the ones they cover. That is also what makes
            // an appearance change a pure repaint: the base colour never has to
            // be written into the storage.
            layoutManager.addTemporaryAttributes([.foregroundColor: baseColor], forCharacterRange: piece)

            for segment in segments {
                let hit = NSIntersectionRange(piece, segment.display)
                guard hit.length > 0 else { continue }
                // display → full, for the run lookup; full → display, to paint.
                let toFull = segment.full.location - segment.display.location
                let fullRange = NSRange(location: hit.location + toFull, length: hit.length)
                HighlightRunList.forEach(highlightRuns, intersecting: fullRange) { runRange, style in
                    let attributes = palette.attributes(for: style)
                    guard !attributes.isEmpty else { return }
                    let display = NSRange(location: runRange.location - toFull, length: runRange.length)
                    guard display.location >= 0, NSMaxRange(display) <= storageLength else { return }
                    layoutManager.addTemporaryAttributes(attributes, forCharacterRange: display)
                }
            }
        }

        /// Remove this pane's temporary attributes over `range`, or over the
        /// whole storage when it is nil.
        private func clearPaintedAttributes(in textView: NSTextView, range: NSRange?) {
            guard let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage,
                  storage.length > 0
            else { return }
            let target = NSIntersectionRange(
                range ?? NSRange(location: 0, length: storage.length),
                NSRange(location: 0, length: storage.length)
            )
            guard target.length > 0 else { return }
            for key in HighlightStyleTable.ownedAttributeKeys {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: target)
            }
        }

        /// The parts of `target` that `painted` does not already cover.
        static func subtracting(_ painted: NSRange, from target: NSRange) -> [NSRange] {
            let hit = NSIntersectionRange(painted, target)
            guard hit.length > 0 else { return [target] }
            var pieces: [NSRange] = []
            if hit.location > target.location {
                pieces.append(NSRange(location: target.location, length: hit.location - target.location))
            }
            if NSMaxRange(hit) < NSMaxRange(target) {
                pieces.append(NSRange(location: NSMaxRange(hit),
                                      length: NSMaxRange(target) - NSMaxRange(hit)))
            }
            return pieces
        }

        /// The character range on screen, widened by
        /// `viewportMarginScreens` above and below.
        func viewportCharacterRange(in textView: NSTextView) -> NSRange? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let storage = textView.textStorage,
                  storage.length > 0
            else { return nil }

            var visibleRect = textView.enclosingScrollView?.documentVisibleRect ?? textView.visibleRect
            if visibleRect.height < 1 { visibleRect = textView.bounds }
            let margin = visibleRect.height * Self.viewportMarginScreens
            let queryRect = visibleRect
                .insetBy(dx: 0, dy: -margin)
                .offsetBy(
                    dx: -textView.textContainerInset.width,
                    dy: -textView.textContainerInset.height
                )
            let glyphRange = layoutManager.glyphRange(forBoundingRect: queryRect, in: textContainer)
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }

            let charRange = layoutManager.characterRange(
                forGlyphRange: glyphRange,
                actualGlyphRange: nil
            )
            guard charRange.location != NSNotFound, charRange.length > 0 else { return nil }
            return NSIntersectionRange(charRange, NSRange(location: 0, length: storage.length))
        }

        /// A fold collapsed or expanded: the runs still describe the same full
        /// text, but every display offset past the fold has moved, so the
        /// painted window means nothing and has to be redone.
        func foldingDidChangeDisplayText(in textView: NSTextView) {
            runsGeneration &+= 1
            paintVisibleHighlights(in: textView)
        }

        /// A text edit moved the text under the runs. Shift them so the viewport
        /// stays right until the engine's next pass lands — which is a debounce
        /// away, and longer on a big file.
        ///
        /// `newRange`/`delta` come from `DiffLayoutManager.processEditing`, in
        /// display coordinates. With a fold open the two coordinate systems
        /// differ, and an edit can even delete a placeholder; rather than guess,
        /// that case keeps the unshifted runs and waits for the rebuild.
        func storageDidEditCharacters(newRange: NSRange, delta: Int) {
            guard comparePeer == nil,
                  !foldingManager.isMutating,
                  foldingManager.regions.isEmpty,
                  !highlightRuns.isEmpty || paintedDisplayRange != nil
            else { return }
            let oldRange = NSRange(
                location: newRange.location,
                length: max(0, newRange.length - delta)
            )
            highlightRuns = HighlightRunList.shifting(
                highlightRuns,
                replacing: oldRange,
                withLength: newRange.length
            )
            // AppKit shifts the temporary attributes with the edit, so the
            // painted window has moved in exactly the same way.
            if let painted = paintedDisplayRange {
                paintedDisplayRange = HighlightRunList.shifting(
                    [HighlightRun(range: painted, style: 1)],
                    replacing: oldRange,
                    withLength: newRange.length
                ).first?.range
            }
        }

        private func editorBaseAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            (textView as? EditorTextView)?.editorBaseAttributes()
                ?? [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.editorForeground,
                    .ligature: 1
                ]
        }

        /// The Thai fallback font is the one highlight-adjacent thing that must
        /// stay a storage attribute — it is a FONT, and a font changes advances,
        /// so it can never ride on the layout manager's temporary attributes.
        /// It is idempotent and only ever adds, so once per new storage plus
        /// once per edited paragraph (`EditorTextView.didChangeText`) covers it.
        /// It used to run over the whole document on every apply.
        private func sweepThaiFontIfStorageIsNew(_ textView: NSTextView) {
            guard storageNeedsThaiSweep else { return }
            storageNeedsThaiSweep = false
            (textView as? EditorTextView)?.applyThaiFontFallback()
        }

        private func visibleParagraphRange(in textView: NSTextView) -> NSRange? {
            guard let storage = textView.textStorage,
                  let range = viewportCharacterRange(in: textView)
            else { return nil }
            return (storage.string as NSString).paragraphRange(for: range)
        }

        func applyEditorBaseColors(to textView: NSTextView) {
            textView.backgroundColor = .editorBackground
            textView.enclosingScrollView?.backgroundColor = .editorBackground
            if let editor = textView as? EditorTextView {
                textView.textColor = editor.editorForegroundColor
                textView.insertionPointColor = editor.editorForegroundColor
            } else {
                textView.textColor = .editorForeground
                textView.insertionPointColor = .editorForeground
            }
        }

        // MARK: - Compare display (filler lines + gutter infos)

        func applyCompareDisplay(
            to textView: EditorTextView,
            document: Document
        ) {
            guard let peer = comparePeer, let side = compareSide else {
                if let storage = textView.textStorage {
                    removeFillerLines(from: storage)
                }
                currentLineInfos = []
                boundGutter?.compareLineInfos = nil
                boundGutter?.compareTransferPointsRight = nil
                boundGutter?.onCompareBlockTransfer = nil
                boundGutter?.needsDisplay = true
                if let diffLM = textView.layoutManager as? DiffLayoutManager {
                    diffLM.lineHighlights = []
                }
                if let lm = textView.layoutManager, let storage = textView.textStorage, storage.length > 0 {
                    lm.removeTemporaryAttribute(.backgroundColor,
                        forCharacterRange: NSRange(location: 0, length: storage.length))
                }
                textView.needsDisplay = true
                return
            }

            let leftText  = side == .left  ? document.text : peer.text
            let rightText = side == .right ? document.text : peer.text

            guard let storage = textView.textStorage else { return }
            if lastCompareLeftText == leftText,
               lastCompareRightText == rightText,
               lastAppliedCompareSide == side {
                return
            }

            // Capture main-thread-only state before going async.
            let savedDisplayLoc = textView.selectedRange().location
            let savedRealLoc    = realTextOffset(for: savedDisplayLoc, in: storage)

            // Mark upfront so repeated SwiftUI updateNSView calls (one per keystroke) hit
            // the early-return guard above instead of each spawning a new background job.
            lastCompareLeftText    = leftText
            lastCompareRightText   = rightText
            lastAppliedCompareSide = side

            let generation = compareApplyGeneration
            let thisVersion = generation.begin()

            DispatchQueue.global(qos: .userInitiated).async { [weak textView] in
                // Bail as soon as a newer keystroke has superseded this job. The
                // version used to be checked only after all of the work below,
                // so every keystroke during a rebuild paid for a full diff and
                // display build whose result was then thrown away.
                guard generation.isCurrent(thisVersion) else { return }

                // Heavy diff + build entirely off the main thread. Both panes are
                // built together and memoised, so the peer's rebuild is a hit.
                let display = CompareEngine.display(leftText: leftText, rightText: rightText, side: side)
                guard generation.isCurrent(thisVersion) else { return }

                // Absolute word-highlight ranges, from the builder's own row
                // ranges. This used to re-derive the rows by walking
                // NSString.paragraphRange, which breaks on a lone CR and on
                // U+2029 while LineHashing.splitLines does not — so one stray CR
                // put every filler attribute, highlight and gutter row after it
                // one line out of step with the text.
                var wordHighlightRanges: [NSRange] = []
                for (info, row) in zip(display.lineInfos, display.rowRanges) {
                    for relRange in info.charHighlights {
                        let absLoc = row.range.location + relRange.location
                        // Clamp to the row's own content: the separator is "\n",
                        // or "\r\n" on a CRLF document, and a highlight reaching
                        // the end of the line used to paint over the CR.
                        let absEnd = min(absLoc + relRange.length, row.range.location + row.contentLength)
                        if absEnd > absLoc {
                            wordHighlightRanges.append(
                                NSRange(location: absLoc, length: absEnd - absLoc)
                            )
                        }
                    }
                }
                let snapshot = CompareLayoutSnapshot(
                    displayText: display.displayText,
                    lineInfos: display.lineInfos,
                    rowRanges: display.rowRanges.map(\.range),
                    wordHighlightRanges: wordHighlightRanges
                )
                guard generation.isCurrent(thisVersion) else { return }

                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, generation.isCurrent(thisVersion) else { return }
                    guard let textView, let storage = textView.textStorage else { return }

                    // The generation counter is only bumped by another
                    // applyCompareDisplay, so a keystroke that landed while this
                    // job was in flight left it looking current. Applying it then
                    // rewrote the storage from the pre-keystroke snapshot — and
                    // since isApplyingCompare suppresses textDidChange and
                    // discardUndoHistory() runs below, the typed character was
                    // gone from the document with no way back. Bail instead, and
                    // drop the memo so the next rebuild is not short-circuited by
                    // the early-return guard at the top.
                    guard CompareApplyGuard.shouldApply(builtFrom: side == .left ? leftText : rightText,
                                                        documentText: self.document.text) else {
                        self.lastCompareLeftText = nil
                        self.lastCompareRightText = nil
                        return
                    }

                    let ns = NSMutableAttributedString(
                        string: snapshot.displayText,
                        attributes: textView.editorBaseAttributes()
                    )
                    for (info, rowRange) in zip(snapshot.lineInfos, snapshot.rowRanges)
                    where info.isFiller {
                        ns.addAttribute(.isFillerLine, value: true, range: rowRange)
                    }

                    let lineHighlights = zip(snapshot.lineInfos, snapshot.rowRanges).compactMap {
                        info, range -> (range: NSRange, color: NSColor)? in
                        guard let color = info.lineBackground else { return nil }
                        return (range: range, color: color)
                    }
                    let wordHighlightColor = side == .left
                        ? NSColor.bestTextCompareWordRemoved
                        : NSColor.bestTextCompareWordAdded

                    self.isApplyingCompare = true
                    defer { self.isApplyingCompare = false }

                    let diffLM = textView.layoutManager as? DiffLayoutManager

                    // Incremental storage update: find the common prefix and suffix, then
                    // replace only the changed middle. This preserves temp attrs on unchanged
                    // ranges and keeps layout invalidation limited to the affected region,
                    // preventing intermediate render frames that cause visible highlight blink.
                    let oldStr = storage.string as NSString
                    let newStr = ns.string as NSString
                    let oldLen = oldStr.length
                    let newLen = newStr.length

                    // Chunked rather than one character(at:) per UTF-16 unit: that
                    // is an ObjC message per character, on the main thread, over
                    // the whole display text on every rebuild.
                    let prefixLen = NSString.commonPrefixLength(oldStr, newStr)
                    let suffixLen = NSString.commonSuffixLength(oldStr, newStr, notBefore: prefixLen)
                    let needsTextReplace = (prefixLen + suffixLen < oldLen) || (prefixLen + suffixLen < newLen)

                    if needsTextReplace {
                        // The storage is about to stop describing what any line
                        // memo was taken against, and it is display text, not
                        // `document.text` (U19/U23).
                        self.noteStorageReplaced(syncedRevision: nil)
                        // Clear lineHighlights before the storage edit so the
                        // DiffLayoutManager.processEditing callback (which adjusts highlight
                        // ranges) doesn't corrupt the values we're about to set.
                        diffLM?.lineHighlights = []
                        let oldRange = NSRange(location: prefixLen,
                                              length: oldLen - prefixLen - suffixLen)
                        let newRange = NSRange(location: prefixLen,
                                              length: newLen - prefixLen - suffixLen)
                        storage.beginEditing()
                        storage.replaceCharacters(in: oldRange,
                                                  with: ns.attributedSubstring(from: newRange))
                        storage.endEditing()
                        // This edit bypasses shouldChangeText, so it registers nothing with
                        // the undo manager while shifting every offset after oldRange —
                        // a later ⌘Z would replay stale ranges into the rebuilt display
                        // text, possibly onto filler lines. Plain typing does NOT reach
                        // here (the common prefix/suffix already covers the user's own
                        // characters), so undo survives ordinary editing; it is dropped
                        // only when the diff itself restructures, which is exactly when
                        // the recorded ranges stop meaning anything.
                        textView.discardUndoHistory()
                    }
                    // Set the correct line highlights now that the storage is final.
                    diffLM?.lineHighlights = lineHighlights

                    // Temp attrs before prefixLen are preserved by the incremental edit.
                    // Clear only from prefixLen onward and re-apply the full word-highlight set
                    // (highlights before prefixLen are identical in the new diff, so re-adding
                    // them is harmless; clearing them separately adds no benefit).
                    if let lm = textView.layoutManager {
                        let clearFrom = needsTextReplace ? prefixLen : 0
                        let clearLen  = storage.length - clearFrom
                        if clearLen > 0 {
                            lm.removeTemporaryAttribute(.backgroundColor,
                                forCharacterRange: NSRange(location: clearFrom, length: clearLen))
                        }
                        for range in snapshot.wordHighlightRanges {
                            let end = range.location + range.length
                            guard end <= storage.length else { continue }
                            lm.addTemporaryAttribute(.backgroundColor, value: wordHighlightColor,
                                forCharacterRange: range)
                        }
                    }

                    self.currentLineInfos = snapshot.lineInfos

                    if needsTextReplace {
                        let newDisplayLoc = self.displayOffset(for: savedRealLoc, in: storage)
                        textView.setSelectedRange(NSRange(location: newDisplayLoc, length: 0))
                    }

                    self.boundGutter?.compareLineInfos = snapshot.lineInfos
                    self.boundGutter?.compareTransferPointsRight = (side == .left)
                    self.boundGutter?.onCompareBlockTransfer = { [weak self] rows in
                        self?.transferCompareBlock(displayRows: rows)
                    }
                    self.boundGutter?.needsDisplay = true
                    textView.needsDisplay = true
                }
            }
        }

        // MARK: - Compare block transfer (copy diff block to other pane)

        /// Called when the user clicks a transfer arrow in this pane's gutter.
        /// Collects the block's real (non-filler) lines from this side and asks the
        /// peer pane's coordinator to splice them in at the aligned position. Display
        /// rows are 1:1 aligned between panes, so the row range needs no translation.
        func transferCompareBlock(displayRows: NSRange) {
            guard let peer = comparePeer,
                  NSMaxRange(displayRows) <= currentLineInfos.count,
                  // Same contiguity check the receiving side applies: a block
                  // whose real lines are not one increasing run has no
                  // well-defined payload order either.
                  CompareTransferGeometry.replaceRange(
                      infos: currentLineInfos, displayRows: displayRows) != nil
            else { return }
            // Split on "\n" only — the same boundary LineHashing.splitLines uses, so
            // realLineNumber indexes this array. On a CRLF document that leaves a
            // trailing "\r" on every line; strip it so the payload is line-ending
            // neutral and the receiving pane can re-terminate it its own way.
            let docLines = document.text.components(separatedBy: "\n")
            var lines: [String] = []
            for idx in displayRows.location ..< NSMaxRange(displayRows) {
                guard let real = currentLineInfos[idx].realLineNumber,
                      real - 1 < docLines.count
                else { continue }
                lines.append(CompareBlockSplice.neutralize(docLines[real - 1]))
            }
            NotificationCenter.default.post(
                name: .compareBlockTransfer,
                object: nil,
                userInfo: [
                    "targetDocumentID": peer.id,
                    "displayRows": NSValue(range: displayRows),
                    "lines": lines
                ]
            )
        }

        /// Peer side of a block transfer: replace this document's real lines covered by
        /// the display-row block with `replacementLines`. An all-filler block on this
        /// side means the lines exist only on the other side — pure insertion after the
        /// nearest real line above. An empty `replacementLines` deletes this side's lines.
        private func applyCompareBlockTransfer(displayRows: NSRange, replacementLines: [String]) {
            let infos = currentLineInfos
            guard !infos.isEmpty,
                  displayRows.location >= 0,
                  NSMaxRange(displayRows) <= infos.count
            else { return }

            guard let (replaceStart, replaceCount) =
                    CompareTransferGeometry.replaceRange(infos: infos, displayRows: displayRows)
            else { return }
            // `replacementLines` arrive line-ending neutral (see transferCompareBlock);
            // CompareBlockSplice re-terminates them for THIS document.
            guard let newText = CompareBlockSplice.apply(
                text: document.text,
                replaceStart: replaceStart,
                replaceCount: replaceCount,
                replacementLines: replacementLines,
                lineEnding: document.lineEnding
            ) else { return }
            document.text = newText
            document.precomputedSyntaxHighlight = nil
            document.isDirty = true
            // Same safety-save pair every other text-mutating path uses; draft-only left
            // an autosave-enabled user's transfer unsaved on quit.
            if let tv = boundTextView {
                scheduleSafetySaves(for: document, textView: tv)
            } else {
                documentStore?.scheduleDraftSave(for: document.id)
            }

            // Rebuild this pane from the new document text, then tell the peer pane
            // (identified as origin so this pane isn't rebuilt twice).
            if let tv = boundTextView as? EditorTextView {
                applyCompareDisplay(to: tv, document: document)
            }
            NotificationCenter.default.post(
                name: .compareDocumentsDidChange,
                object: nil,
                userInfo: ["documentID": document.id]
            )
        }

        /// Convert a display-text character offset to a real-text character offset
        /// by skipping filler line characters.
        ///
        /// Lines are found by scanning for LF, and filler-ness is read from the
        /// `.isFillerLine` attribute on the line's first character — the same
        /// truth `realText(from:)` uses, and the only one that survives the user
        /// typing into the storage between two rebuilds. The old walk paired
        /// `NSString.paragraphRange` results with the row array one for one,
        /// which desynchronised on any lone CR, and cost one ObjC round trip per
        /// line on the main thread.
        private func realTextOffset(for displayLoc: Int, in storage: NSTextStorage) -> Int {
            guard storage.length > 0 else { return 0 }
            var realCount = 0
            var displayCount = 0
            CompareDisplayLines.forEachLine(in: storage) { lineRange, isFiller in
                if displayCount + lineRange.length > displayLoc {
                    if !isFiller { realCount += displayLoc - displayCount }
                    return false
                }
                if !isFiller { realCount += lineRange.length }
                displayCount += lineRange.length
                return true
            }
            return realCount
        }

        /// Convert a real-text character offset back to a display-text offset,
        /// adding filler line lengths.
        private func displayOffset(for realLoc: Int, in storage: NSTextStorage) -> Int {
            guard storage.length > 0 else { return 0 }
            var realCount = 0
            var displayCount = 0
            var answer: Int? = nil
            CompareDisplayLines.forEachLine(in: storage) { lineRange, isFiller in
                if !isFiller {
                    if realCount + lineRange.length > realLoc {
                        answer = displayCount + (realLoc - realCount)
                        return false
                    }
                    realCount += lineRange.length
                }
                displayCount += lineRange.length
                return true
            }
            return answer ?? min(displayCount, storage.length)
        }

        private func removeFillerLines(from storage: NSTextStorage) {
            var ranges: [NSRange] = []
            CompareDisplayLines.forEachLine(in: storage) { lineRange, isFiller in
                if isFiller { ranges.append(lineRange) }
                return true
            }
            // Remove back-to-front so ranges stay valid.
            for range in ranges.reversed() {
                storage.replaceCharacters(in: range, with: "")
            }
        }

        /// Debounced re-highlight on typing.
        /// Delay scales with file size so large files don't thrash the syntax queue.
        private var rehighlightWorkItem: DispatchWorkItem?
        private var highlightGeneration: Int = 0
        private func scheduleRehighlight(textView: NSTextView) {
            rehighlightWorkItem?.cancel()
            if document.isLargeFileModeActive {
                // Large-file mode never highlights, so there is nothing to
                // refresh. This used to `setAttributes` over the whole document
                // on EVERY keystroke to scrub syntax colours that, in this mode,
                // were never applied in the first place.
                return
            }
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlight(to: textView, document: self.document)
            }
            rehighlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + rehighlightDelay, execute: item)
        }

        private var rehighlightDelay: TimeInterval {
            // Document keeps this in sync in text.didSet; recounting here was a full
            // scan of the file on every keystroke.
            let count = document.textUTF16Count
            switch count {
            case ..<20_000:  return 0.08
            case ..<100_000: return 0.15
            case ..<500_000: return 0.30
            default:         return 0.50
            }
        }

        /// Debounced compare-display rebuild after typing in either pane.
        private var compareDisplayWorkItem: DispatchWorkItem?
        private var deferredHighlightWorkItem: DispatchWorkItem?
        private func scheduleCompareDisplay(textView: EditorTextView, document: Document) {
            compareDisplayWorkItem?.cancel()
            guard !isLargeCompareContext else { return }
            let peerText = comparePeer?.text ?? ""
            let leftText = compareSide == .left ? document.text : peerText
            let rightText = compareSide == .right ? document.text : peerText
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyCompareDisplay(to: textView, document: document)
                // Notify peer pane to rebuild too.
                NotificationCenter.default.post(
                    name: .compareDocumentsDidChange,
                    object: nil,
                    userInfo: ["documentID": document.id]
                )
            }
            compareDisplayWorkItem = item
            let delay = CompareEngine.liveEditDelay(leftText: leftText, rightText: rightText)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        private var isLargeCompareContext: Bool {
            document.isLargeFileModeActive || comparePeer?.isLargeFileModeActive == true
        }

        // MARK: - Modified-since-save gutter marks

        private var savedLineMarksTask: Task<Void, Never>?

        func scheduleSavedLineMarks() {
            savedLineMarksTask?.cancel()
            guard comparePeer == nil else { return }  // compare mode has its own gutter
            guard let baseline = document.savedText else {
                boundGutter?.savedLineMarks = [:]
                return
            }
            let currentText = document.text
            savedLineMarksTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                let markStyles = await Task.detached(priority: .utility) {
                    Self.computeSavedLineMarks(saved: baseline, current: currentText)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.boundGutter?.savedLineMarks = markStyles.mapValues { style in
                    switch style {
                    case .added: return .bestTextSuccess
                    case .modified: return .editorModifiedAmber
                    case .deleted: return .bestTextDanger
                    }
                }
            }
        }

        nonisolated static func computeSavedLineMarks(
            saved: String,
            current: String
        ) -> [Int: SavedLineMarkStyle] {
            let savedLines   = saved.components(separatedBy: "\n")
            let currentLines = current.components(separatedBy: "\n")

            // Intern the lines first: this runs on every keystroke outside
            // compare mode, and feeding raw Strings to the DP made each of its
            // n*m equality tests a String comparison. Only the SHAPE of the op
            // sequence is read below — the line text never is — so diffing ids
            // is equivalent, and interning preserves the equality relation
            // exactly, which is all DiffCalc's tie-breaks depend on.
            var lineIDs: [String: Int32] = [:]
            lineIDs.reserveCapacity(savedLines.count + currentLines.count)
            var nextLineID: Int32 = 0
            func intern(_ lines: [String]) -> [Int32] {
                lines.map { line in
                    if let id = lineIDs[line] { return id }
                    let id = nextLineID
                    lineIDs[line] = id
                    nextLineID += 1
                    return id
                }
            }
            let ops = DiffCalc.diff(intern(savedLines), intern(currentLines)) { $0 == $1 }

            // Group consecutive onlyInA/onlyInB runs.
            // Mixed run (deletions + insertions) → modified (amber).
            // Pure insert run → added (green).
            var marks: [Int: SavedLineMarkStyle] = [:]
            var currentLineNum = 1

            var i = 0
            while i < ops.count {
                switch ops[i] {
                case .match:
                    currentLineNum += 1
                    i += 1

                case .onlyInA, .onlyInB:
                    var deleteCount = 0
                    var insertCount = 0
                    runLoop: while i < ops.count {
                        switch ops[i] {
                        case .onlyInA: deleteCount += 1; i += 1
                        case .onlyInB: insertCount += 1; i += 1
                        default: break runLoop
                        }
                    }
                    guard insertCount > 0 else {
                        // Deletion only: the run consumed lines that no longer
                        // exist, so it owns no row of its own. Mark the line the
                        // text closed up onto — clamped to the last line, for a
                        // deletion at the very end — and never over a mark an
                        // adjacent edit already claimed.
                        if deleteCount > 0 {
                            let joinLine = min(currentLineNum, max(1, currentLines.count))
                            if marks[joinLine] == nil { marks[joinLine] = .deleted }
                        }
                        continue
                    }
                    let style: SavedLineMarkStyle = deleteCount > 0 ? .modified : .added
                    for _ in 0..<insertCount {
                        marks[currentLineNum] = style
                        currentLineNum += 1
                    }
                }
            }
            return marks
        }

        private func visibleSegments(in storage: NSTextStorage) -> [(full: NSRange, display: NSRange)] {
            let sorted = foldingManager.regions.sorted { $0.displayLocation < $1.displayLocation }
            var segments: [(full: NSRange, display: NSRange)] = []

            var fullPos = 0
            var displayPos = 0

            for region in sorted {
                let visibleLen = max(0, region.displayLocation - displayPos)
                if visibleLen > 0 {
                    segments.append((
                        full: NSRange(location: fullPos, length: visibleLen),
                        display: NSRange(location: displayPos, length: visibleLen)
                    ))
                }

                // UTF-16 units: `fullPos` indexes the same coordinate space as the
                // NSRanges built from it. Character count would drift on CRLF,
                // emoji or Thai combining pairs.
                fullPos += visibleLen + region.originalUTF16Length
                displayPos += visibleLen + 1
            }

            let tailLen = max(0, storage.length - displayPos)
            if tailLen > 0 {
                segments.append((
                    full: NSRange(location: fullPos, length: tailLen),
                    display: NSRange(location: displayPos, length: tailLen)
                ))
            }

            return segments
        }

        /// Wipe every attribute back to the editor's base ones.
        ///
        /// This is not part of the highlight path any more — the highlight
        /// never puts anything in the storage. It is what large-file mode and an
        /// unsupported language do: drop the runs, scrub the paint, and make
        /// sure the storage carries nothing but base attributes.
        private func resetHighlightAttributes(
            in storage: NSTextStorage,
            baseAttributes: [NSAttributedString.Key: Any]
        ) {
            if let textView = boundTextView { dropHighlightRuns(clearingPaintIn: textView) }
            let range = NSRange(location: 0, length: storage.length)
            guard range.length > 0 else { return }

            // A collapsed fold is one U+FFFC carrying an `.attachment`, and
            // `setAttributes` REPLACES the dictionary — so the wipe below
            // deletes it and the "{ 3 lines }" pill turns into a bare
            // object-replacement character. Restoring them afterwards keeps the
            // wipe covering the whole storage, which is what stops a drifted
            // region from leaving stale attributes behind.
            let ns = storage.string as NSString
            let placeholders: [(NSRange, [NSAttributedString.Key: Any])] =
                foldingManager.regions.compactMap { region in
                    let loc = region.displayLocation
                    guard loc >= 0, loc < ns.length, ns.character(at: loc) == 0xFFFC
                    else { return nil }
                    return (NSRange(location: loc, length: 1),
                            storage.attributes(at: loc, effectiveRange: nil))
                }

            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: range)
            for (placeholderRange, attributes) in placeholders {
                storage.setAttributes(attributes, range: placeholderRange)
            }
            storage.endEditing()
            applyThaiFontFallback(to: storage, range: range)
        }

        private func applyThaiFontFallback(to storage: NSTextStorage, range: NSRange) {
            for layoutManager in storage.layoutManagers {
                if let editor = (layoutManager as? DiffLayoutManager)?.ownerTextView as? EditorTextView {
                    editor.applyThaiFontFallback(in: range)
                    return
                }
            }
        }

        private static func storeSyntaxHighlight(
            _ entry: SyntaxHighlightCacheEntry?,
            for id: Document.ID
        ) {
            if let entry {
                syntaxHighlightCache[id] = entry
                syntaxHighlightCacheOrder.removeAll { $0 == id }
                syntaxHighlightCacheOrder.append(id)
                // Sweep entries whose document has gone away. Belt and braces
                // for the explicit `discardSyntaxHighlight` above: a document
                // that nothing holds any more cannot be repainted, so its run
                // list is pure resident memory (S5).
                syntaxHighlightCacheOrder.removeAll { candidate in
                    guard candidate != id,
                          let stale = syntaxHighlightCache[candidate],
                          stale.document == nil
                    else { return false }
                    syntaxHighlightCache.removeValue(forKey: candidate)
                    return true
                }
                while syntaxHighlightCacheOrder.count > syntaxHighlightCacheLimit {
                    let removed = syntaxHighlightCacheOrder.removeFirst()
                    syntaxHighlightCache.removeValue(forKey: removed)
                }
            } else {
                syntaxHighlightCache.removeValue(forKey: id)
                syntaxHighlightCacheOrder.removeAll { $0 == id }
            }
        }
    }
}

/// The one door into the syntax-highlight run cache the editor coordinators
/// share. The coordinator (and the representable around it) are file-private; a
/// closed document still has to be able to evict its entry — a run list for the
/// whole file, which is far smaller than the attributed string it replaced but
/// still grows with the document.
///
/// Call from `DocumentStore.close` / `closeAllTabs`, beside the existing
/// `SyntaxEngine.shared.discardSession(for:)`.
@MainActor
enum EditorHighlightCache {
    static func discard(for id: Document.ID) {
        EditorRepresentable.Coordinator.discardSyntaxHighlight(for: id)
    }
}

extension Notification.Name {
    static let compareDocumentsDidChange = Notification.Name("sheeptext.compare.documentsDidChange")
    static let compareBlockTransfer      = Notification.Name("sheeptext.compare.blockTransfer")
    static let compareSyncScroll         = Notification.Name("sheeptext.compare.syncScroll")
    static let documentDidSave           = Notification.Name("sheeptext.document.didSave")
}

nonisolated private enum CompareDisplayBuilder {
    // .changed rows already passed the char-level resemblance check → always show word diff.
    // .paired rows are adjacent add/remove with no prior resemblance check → need some baseline.
    private static let pairedWordDiffThreshold = 40
    private static let wordDiffTokenLimit = 300
    private static let wordDiffTokenProductLimit = 60_000

    /// Builds BOTH panes from one pass over the rows.
    ///
    /// It used to be called once per pane, and each call ran the word-level diff
    /// over the same pair of lines — so a `.changed` row was tokenised four
    /// times (mine + other, twice) and diffed twice, for two results that are
    /// just the `onlyInA` and `onlyInB` halves of a single op stream.
    static func build(rows: [CompareRow]) -> (left: CompareDisplay, right: CompareDisplay) {
        var leftLines: [String] = [];  var leftInfos: [CompareLineInfo] = []
        var rightLines: [String] = []; var rightInfos: [CompareLineInfo] = []
        leftLines.reserveCapacity(rows.count);  leftInfos.reserveCapacity(rows.count)
        rightLines.reserveCapacity(rows.count); rightInfos.reserveCapacity(rows.count)

        for row in rows {
            let highlights = wordHighlights(for: row)
            appendRow(row, side: .left,  highlights: highlights.left,  into: &leftLines,  infos: &leftInfos)
            appendRow(row, side: .right, highlights: highlights.right, into: &rightLines, infos: &rightInfos)
        }

        return (assemble(lines: leftLines, infos: leftInfos),
                assemble(lines: rightLines, infos: rightInfos))
    }

    private static func appendRow(
        _ row: CompareRow,
        side: ComparePaneSide,
        highlights: [NSRange],
        into lines: inout [String],
        infos: inout [CompareLineInfo]
    ) {
        let isLeft = side == .left
        let text: String?
        let realLine: Int?
        let isFiller: Bool
        var mapped: Int? = nil

        switch row.kind {
        case .same, .changed:
            text     = isLeft ? row.leftText : row.rightText
            realLine = isLeft ? row.leftLineNumber : row.rightLineNumber
            isFiller = (text == nil)

        case .leftOnly, .rightOnly, .paired:
            // Each of these carries text for at most one side; the other side is
            // the blank filler that keeps the two panes' rows aligned.
            text     = isLeft ? row.leftText : row.rightText
            realLine = isLeft ? row.leftLineNumber : row.rightLineNumber
            isFiller = (text == nil)

        case .moved:
            // One-sided by construction (see detectMovedRows): the row sits where
            // the diff put it and the peer pane shows a filler in its place.
            text     = isLeft ? row.leftText : row.rightText
            realLine = isLeft ? row.leftLineNumber : row.rightLineNumber
            isFiller = (text == nil)
            mapped   = isFiller ? nil : row.movedCounterpartLine
        }

        lines.append(isFiller ? "" : (text ?? ""))
        infos.append(CompareLineInfo(
            realLineNumber: realLine,
            isFiller: isFiller,
            gutterSymbol: symbol(for: row.kind, side: side, isFiller: isFiller),
            style: style(for: row.kind, side: side, isFiller: isFiller),
            mappedLineNumber: mapped,
            charHighlights: isFiller ? [] : highlights
        ))
    }

    /// Joins the rows and hands back the exact range of each one, so nothing
    /// downstream has to re-derive line boundaries from the text.
    private static func assemble(lines: [String], infos: [CompareLineInfo]) -> CompareDisplay {
        var ranges: [CompareRowRange] = []
        ranges.reserveCapacity(lines.count)
        var location = 0
        for line in lines {
            // Raw lines keep a trailing CR on a CRLF document; it is part of the
            // row but not of its visible content, which is what a word highlight
            // may extend to.
            let length = (line as NSString).length
            let content = line.hasSuffix("\r") ? length - 1 : length
            ranges.append(CompareRowRange(range: NSRange(location: location, length: length + 1),
                                          contentLength: content))
            location += length + 1
        }
        // Join with newlines; add a trailing newline so the last row is complete
        // — which is what makes every row's range include exactly one "\n".
        let displayText = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        return CompareDisplay(displayText: displayText, lineInfos: infos, rowRanges: ranges)
    }

    // MARK: - Word-level diff

    /// A token is a range into the line's UTF-16 buffer. It used to carry the
    /// substring as a `String` as well, i.e. one heap allocation per token per
    /// line per pane.
    private struct WordToken: Sendable {
        let utf16Offset: Int32
        let utf16Length: Int32
    }

    /// Splits `units` into word tokens (alphanumeric/underscore runs) and single-char separators.
    private static func tokenize(_ units: [unichar]) -> [WordToken] {
        var tokens: [WordToken] = []
        tokens.reserveCapacity(units.count / 3 + 1)
        var i = 0
        while i < units.count {
            if isWordChar(units[i]) {
                var j = i + 1
                while j < units.count && isWordChar(units[j]) { j += 1 }
                tokens.append(WordToken(utf16Offset: Int32(i), utf16Length: Int32(j - i)))
                i = j
            } else {
                tokens.append(WordToken(utf16Offset: Int32(i), utf16Length: 1))
                i += 1
            }
        }
        return tokens
    }

    /// Anything outside ASCII counts as a word character. It used to be ASCII
    /// only, so every Thai or CJK character became its own one-character token
    /// — a 150-row Thai diff cost 13 ms instead of 1 ms, and the highlights it
    /// produced were per-character confetti rather than per-word spans.
    private static func isWordChar(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c >= 0x80
    }

    private static func utf16Units(_ string: String) -> [unichar] {
        let ns = string as NSString
        var units = [unichar](repeating: 0, count: ns.length)
        if ns.length > 0 { ns.getCharacters(&units, range: NSRange(location: 0, length: ns.length)) }
        return units
    }

    /// Word-level diff highlights for BOTH panes, relative to each line's start.
    /// Adjacent changed word-tokens are merged into one background span.
    private static func wordHighlights(for row: CompareRow) -> (left: [NSRange], right: [NSRange]) {
        let empty: (left: [NSRange], right: [NSRange]) = ([], [])
        switch row.kind {
        case .changed, .paired: break
        default: return empty
        }
        guard let leftText = row.leftText, let rightText = row.rightText else { return empty }
        guard leftText != rightText else { return empty }

        let leftUnits  = utf16Units(leftText)
        let rightUnits = utf16Units(rightText)
        let leftTokens  = tokenize(leftUnits)
        let rightTokens = tokenize(rightUnits)
        guard !leftTokens.isEmpty,
              !rightTokens.isEmpty,
              leftTokens.count <= wordDiffTokenLimit,
              rightTokens.count <= wordDiffTokenLimit,
              leftTokens.count * rightTokens.count <= wordDiffTokenProductLimit
        else { return empty }

        // One op stream for the pair: .onlyInA is what only the left line has,
        // .onlyInB what only the right line has.
        // Token equality compares the code units in place. The tokens used to
        // carry their own `String`, which is a heap allocation per token per
        // line per pane. (The buffers are captured as arrays, not as unsafe
        // pointers: `DiffCalc.diff`'s predicate is @Sendable.)
        let ops: [DiffOp<WordToken>] = DiffCalc.diff(leftTokens, rightTokens) { a, b in
            guard a.utf16Length == b.utf16Length else { return false }
            let count = Int(a.utf16Length)
            let aStart = Int(a.utf16Offset)
            let bStart = Int(b.utf16Offset)
            var i = 0
            while i < count {
                if leftUnits[aStart + i] != rightUnits[bStart + i] { return false }
                i += 1
            }
            return true
        }

        // .changed rows already passed char-level resemblance — always show word highlights.
        // .paired rows need a minimum similarity to avoid noisy highlights on unrelated lines.
        if row.kind == .paired {
            guard similarityPercent(from: ops) >= pairedWordDiffThreshold else { return empty }
        }

        return (spans(in: ops, side: .left), spans(in: ops, side: .right))
    }

    /// Merges the run of tokens present on `side` only into background spans.
    private static func spans(in ops: [DiffOp<WordToken>], side: ComparePaneSide) -> [NSRange] {
        var result: [NSRange] = []
        var runStart = -1
        var runEnd   = -1

        func flush() {
            if runStart >= 0 { result.append(NSRange(location: runStart, length: runEnd - runStart)) }
            runStart = -1; runEnd = -1
        }
        func extend(_ token: WordToken) {
            if runStart < 0 { runStart = Int(token.utf16Offset) }
            runEnd = Int(token.utf16Offset + token.utf16Length)
        }

        for op in ops {
            switch op {
            case .match: flush()
            case .onlyInA(let t): if side == .left  { extend(t) }
            case .onlyInB(let t): if side == .right { extend(t) }
            }
        }
        flush()
        return result
    }

    /// Character-based similarity: counts matched UTF-16 units so long tokens (e.g. identifiers)
    /// and short tokens (e.g. spaces) contribute proportionally, not equally.
    private static func similarityPercent(from ops: [DiffOp<WordToken>]) -> Int {
        var matched = 0
        var leftChars = 0
        var rightChars = 0
        for op in ops {
            switch op {
            case .match(let a, _):
                matched    += Int(a.utf16Length)
                leftChars  += Int(a.utf16Length)
                rightChars += Int(a.utf16Length)
            case .onlyInA(let a):
                leftChars  += Int(a.utf16Length)
            case .onlyInB(let b):
                rightChars += Int(b.utf16Length)
            }
        }
        let denom = max(leftChars, rightChars)
        guard denom > 0 else { return 100 }
        return Int((Double(matched) / Double(denom)) * 100.0)
    }

    private static func symbol(for kind: CompareRow.Kind, side: ComparePaneSide, isFiller: Bool) -> String {
        if isFiller { return "" }
        switch kind {
        case .same:     return ""
        case .changed:  return "~"
        case .leftOnly: return side == .left  ? "−" : ""
        case .rightOnly:return side == .right ? "+" : ""
        case .paired:   return side == .left  ? "−" : "+"
        case .moved:    return "↕"
        }
    }

    private static func style(
        for kind: CompareRow.Kind,
        side: ComparePaneSide,
        isFiller: Bool
    ) -> CompareLineStyle {
        if isFiller { return .filler }
        switch kind {
        case .same: return .same
        case .changed: return side == .left ? .changedLeft : .changedRight
        case .leftOnly: return side == .left ? .removed : .same
        case .rightOnly: return side == .right ? .added : .same
        case .paired: return side == .left ? .removed : .added
        case .moved: return .moved
        }
    }
}

private struct EmptyStateView: View {
    @Environment(DocumentStore.self)  private var documents
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No file open")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    documents.newUntitled()
                } label: {
                    Label("New File", systemImage: "doc.badge.plus")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    for url in workspace.promptOpenFiles() {
                        documents.open(url: url)
                    }
                } label: {
                    Label("Open File…", systemImage: "doc")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button("Open a folder as workspace…") {
                workspace.promptOpenFolder()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Benchmark seam

/// Read only by `SheepTextTests/PerfHarnessTests`. `CompareEngine` and its row
/// types are file-private on purpose; this exposes a checksum-shaped view of a
/// full compare so the perf harness can time the real pipeline without
/// widening the API.
nonisolated enum CompareBenchmarkSeam {
    /// Histogram of row kinds (same, changed, leftOnly, rightOnly, moved,
    /// paired, total) for a compare built from scratch — the cache is cleared
    /// first so every call does the whole computation.
    ///
    /// `liveEdit` is accepted and ignored. There used to be a second, index
    /// aligned build mode that any pair of files over ~425x425 lines fell into
    /// and never left; with the Myers diff behind it there is one mode.
    static func rowHistogram(left: String, right: String, liveEdit: Bool = false) -> [Int] {
        CompareEngine.clearCache()
        return histogram(of: CompareEngine.buildRows(leftText: left, rightText: right))
    }

    private static func histogram(of rows: [CompareRow]) -> [Int] {
        var histogram = [Int](repeating: 0, count: 7)
        for row in rows {
            switch row.kind {
            case .same:      histogram[0] += 1
            case .changed:   histogram[1] += 1
            case .leftOnly:  histogram[2] += 1
            case .rightOnly: histogram[3] += 1
            case .moved:     histogram[4] += 1
            case .paired:    histogram[5] += 1
            }
        }
        histogram[6] = rows.count
        return histogram
    }

    /// The counts the compare header shows, for the same pair of documents.
    static func headerCounts(left: String, right: String) -> [Int] {
        CompareEngine.clearCache()
        let counts = CompareDiffCounter.make(leftText: left, rightText: right)
        return [counts.removed, counts.added, counts.changed, counts.moved]
    }

    /// One row of one pane, as the display layer sees it.
    struct RowProbe: Sendable {
        /// "s" same, "c" changed, "l" leftOnly, "r" rightOnly, "m" moved, "p" paired.
        public let kind: String
        public let text: String
        public let realLineNumber: Int?
        public let mappedLineNumber: Int?
        public let isFiller: Bool
        public let gutterSymbol: String
        /// Full row range in the display text, including the trailing "\n".
        public let range: NSRange
        /// Word-highlight ranges, absolute in the display text and clamped to
        /// the row's own content.
        public let wordHighlights: [NSRange]
    }

    struct DisplayProbe: Sendable {
        public let displayText: String
        public let rows: [RowProbe]
        /// Ranges carrying the `.isFillerLine` attribute, in row order.
        public var fillerRanges: [NSRange] { rows.filter(\.isFiller).map(\.range) }
    }

    /// Builds one pane exactly as `applyCompareDisplay` does, minus AppKit.
    static func displayProbe(left: String, right: String, leftSide: Bool) -> DisplayProbe {
        CompareEngine.clearCache()
        let side: ComparePaneSide = leftSide ? .left : .right
        let rows = CompareEngine.buildRows(leftText: left, rightText: right)
        let display = CompareEngine.display(leftText: left, rightText: right, side: side)
        let ns = display.displayText as NSString
        var probes: [RowProbe] = []
        for (index, info) in display.lineInfos.enumerated() {
            let rowRange = display.rowRanges[index]
            var highlights: [NSRange] = []
            for relRange in info.charHighlights {
                let absLoc = rowRange.range.location + relRange.location
                let absEnd = min(absLoc + relRange.length, rowRange.range.location + rowRange.contentLength)
                if absEnd > absLoc { highlights.append(NSRange(location: absLoc, length: absEnd - absLoc)) }
            }
            let kind: String
            switch rows[index].kind {
            case .same: kind = "s"
            case .changed: kind = "c"
            case .leftOnly: kind = "l"
            case .rightOnly: kind = "r"
            case .moved: kind = "m"
            case .paired: kind = "p"
            }
            probes.append(RowProbe(
                kind: kind,
                text: ns.substring(with: NSRange(location: rowRange.range.location, length: rowRange.contentLength)),
                realLineNumber: info.realLineNumber,
                mappedLineNumber: info.mappedLineNumber,
                isFiller: info.isFiller,
                gutterSymbol: info.gutterSymbol,
                range: rowRange.range,
                wordHighlights: highlights
            ))
        }
        return DisplayProbe(displayText: display.displayText, rows: probes)
    }

    /// Row kinds of the shared row array, one character each.
    static func rowKinds(left: String, right: String) -> String {
        String(displayProbe(left: left, right: right, leftSide: true).rows.map { Character($0.kind) })
    }

    /// What a block transfer of `displayRows` from this pane would compute, or
    /// nil when the transfer is refused.
    static func transferReplaceRange(
        left: String, right: String, leftSide: Bool, displayRows: NSRange
    ) -> (start: Int, count: Int)? {
        let side: ComparePaneSide = leftSide ? .left : .right
        CompareEngine.clearCache()
        let display = CompareEngine.display(leftText: left, rightText: right, side: side)
        return CompareTransferGeometry.replaceRange(infos: display.lineInfos, displayRows: displayRows)
    }

    /// Checksum over both panes' built display, for the perf harness: the whole
    /// display build including the word-level diff, from a cold cache.
    static func displayChecksum(left: String, right: String) -> Int {
        CompareEngine.clearCache()
        var checksum = 0
        for leftSide in [true, false] {
            let display = CompareEngine.display(leftText: left, rightText: right, side: leftSide ? .left : .right)
            checksum &+= (display.displayText as NSString).length
            for info in display.lineInfos {
                checksum &+= info.charHighlights.count
                for range in info.charHighlights { checksum &+= range.location &+ range.length }
            }
        }
        return checksum
    }
}

// MARK: - Audit seam (DEBUG)

#if DEBUG
/// Test seam for the September 2026 editor-view audit fixes.
///
/// `EditorRepresentable` and its `Coordinator` are file-private on purpose —
/// nothing outside this file drives an editor pane. The findings fixed here
/// (S3, S5, S9, U8, U17, U25) all live in the coordinator, so this exposes the
/// few decisions they turn on, in the same spirit as `CompareBenchmarkSeam`
/// above: no widening of the shipping API.
@MainActor
enum EditorViewAuditSeam {

    // MARK: U25 — modified-since-save marks

    /// `computeSavedLineMarks`, with the style spelled as a string so the
    /// file-private enum stays file-private. "added" / "modified" / "deleted".
    static func savedLineMarks(saved: String, current: String) -> [Int: String] {
        EditorRepresentable.Coordinator.computeSavedLineMarks(saved: saved, current: current)
            .mapValues { style in
                switch style {
                case .added: return "added"
                case .modified: return "modified"
                case .deleted: return "deleted"
                }
            }
    }

    // MARK: S5 — whole-document highlight cache

    static var highlightCacheLimit: Int {
        EditorRepresentable.Coordinator.syntaxHighlightCacheLimitForTesting
    }

    static var highlightCacheCount: Int {
        EditorRepresentable.Coordinator.syntaxHighlightCacheCountForTesting
    }

    static func highlightCacheContains(_ id: Document.ID) -> Bool {
        EditorRepresentable.Coordinator.syntaxHighlightCacheContainsForTesting(id)
    }

    /// Stores a small entry for `document`, exactly the way a finished
    /// highlight does.
    static func storeHighlight(for document: Document) {
        EditorRepresentable.Coordinator.storeSyntaxHighlightForTesting(for: document)
    }

    static func clearHighlightCache() {
        EditorRepresentable.Coordinator.clearSyntaxHighlightCacheForTesting()
    }

    // MARK: U17 — appearance-guarded invalidation

    static var applyHighlightCallCount: Int {
        get { EditorRepresentable.Coordinator.applyHighlightCallCount }
        set { EditorRepresentable.Coordinator.applyHighlightCallCount = newValue }
    }

    /// How many viewport paints have run, and how many characters the last one
    /// covered. The whole point of the design is that the second number tracks
    /// the SCREEN and not the file, so it is asserted rather than assumed.
    static var viewportPaintCount: Int {
        get { EditorRepresentable.Coordinator.viewportPaintCount }
        set { EditorRepresentable.Coordinator.viewportPaintCount = newValue }
    }

    static var lastPaintedCharacterCount: Int {
        EditorRepresentable.Coordinator.lastPaintedCharacterCount
    }

    /// A coordinator bound to a real TextKit 1 stack, with no window and no
    /// notification observers (`startObserving` is deliberately not called —
    /// its observers are global broadcasts and would fire across tests).
    final class Probe {
        let document: Document
        let textView: EditorTextView
        let storage: NSTextStorage
        /// A real clip view, so `documentVisibleRect` is a viewport and not the
        /// whole document — without it every "paints only what is on screen"
        /// assertion would pass vacuously.
        let scrollView: NSScrollView
        let cursor = CursorState()
        private let coordinator: EditorRepresentable.Coordinator

        init(text: String, language: String = "plaintext", viewportHeight: CGFloat = 200) {
            document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
            document.language = language
            storage = NSTextStorage(string: text)
            let layoutManager = DiffLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(
                size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
            )
            container.widthTracksTextView = true
            layoutManager.addTextContainer(container)
            textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: viewportHeight),
                                      textContainer: container)
            textView.isRichText = false
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.autoresizingMask = [.width]
            scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: viewportHeight))
            scrollView.hasVerticalScroller = true
            scrollView.documentView = textView
            layoutManager.ownerTextView = textView
            coordinator = EditorRepresentable.Coordinator(document: document)
            coordinator.boundTextView = textView
            coordinator.boundScrollView = scrollView
            coordinator.cursorState = cursor
            textView.document = document
            textView.foldingManager = coordinator.foldingManager
            // `startObserving` is deliberately not called (its observers are
            // global broadcasts and would fire across tests), so the one hook
            // the paint layer needs is wired by hand.
            layoutManager.onCharactersEdited = { [weak coordinator] range, delta in
                coordinator?.storageDidEditCharacters(newRange: range, delta: delta)
            }
            // Force a first layout so glyph ranges exist for the viewport query,
            // then pin the document view back to the clip view's origin: growing
            // a resizable text view outside a window leaves its frame origin
            // where the layout put it, and every `documentVisibleRect` after
            // that is offset by the whole document's height.
            layoutManager.ensureLayout(for: container)
            textView.setFrameOrigin(.zero)
            scrollView.layoutSubtreeIfNeeded()
        }

        var foldingManager: FoldingManager { coordinator.foldingManager }

        var baseAttributes: [NSAttributedString.Key: Any] { textView.editorBaseAttributes() }

        /// What `updateNSView`'s U19 shortcut asks before deciding whether it
        /// has to reconstruct the full text and compare it.
        var storageIsInSyncWithDocument: Bool {
            coordinator.storageIsInSyncWithDocument(storageLength: storage.length)
        }

        // MARK: Runs in, paint out

        /// Hand the coordinator a complete run list, exactly as a finished
        /// engine pass does, and let it paint the viewport.
        func setRuns(_ runs: [HighlightRun]) {
            coordinator.setHighlightRuns(runs, in: textView)
        }

        var runs: [HighlightRun] { coordinator.highlightRuns }

        /// Repaint without changing the runs — what a scroll, a resize or a
        /// fold does.
        func paintViewport() {
            coordinator.paintVisibleHighlights(in: textView)
        }

        /// Drop the runs and scrub every temporary attribute this pane owns.
        func dropRuns() {
            coordinator.dropHighlightRuns(clearingPaintIn: textView)
        }

        var viewportRange: NSRange? { coordinator.viewportCharacterRange(in: textView) }

        /// The appearance the paint resolves its colours under.
        var isDark: Bool { coordinator.resolvedIsDark(for: textView) }

        /// What `textDidChange` does after a fold mutation.
        func foldingDidChangeDisplayText() {
            coordinator.foldingDidChangeDisplayText(in: textView)
        }

        /// What the appearance observers do.
        func applyEditorAppearance() {
            coordinator.applyEditorBaseColors(to: textView)
        }

        /// Scroll the clip view and repaint, the way the bounds observer does.
        func scroll(toY y: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.paintVisibleHighlights(in: textView)
        }

        /// The layout manager's temporary foreground colour at each character —
        /// what the user actually sees. `nil` means nothing was painted there.
        func paintedForegroundColors() -> [NSColor?] {
            guard let layoutManager = textView.layoutManager else { return [] }
            return (0..<storage.length).map { index in
                layoutManager.temporaryAttribute(
                    .foregroundColor, atCharacterIndex: index, effectiveRange: nil
                ) as? NSColor
            }
        }

        /// How many characters carry a painted foreground colour.
        func paintedCharacterCount() -> Int {
            paintedForegroundColors().reduce(0) { $0 + ($1 == nil ? 0 : 1) }
        }

        /// Every attribute key present in the STORAGE, anywhere. The invariant
        /// is that syntax colouring never appears here.
        func storageAttributeKeys() -> Set<String> {
            var keys: Set<String> = []
            storage.enumerateAttributes(
                in: NSRange(location: 0, length: storage.length), options: []
            ) { attributes, _, _ in
                for key in attributes.keys { keys.insert(key.rawValue) }
            }
            return keys
        }

        /// Enter or leave compare mode, the way `updateNSView` does.
        func setComparePeer(_ peer: Document?) {
            coordinator.updateCompareContext(peer: peer, side: peer == nil ? nil : .left)
        }

        func applyHighlightNow() {
            coordinator.applyHighlight(to: textView, document: document)
        }

                func invalidateHighlightingAfterExternalChange(force: Bool = false) {
            coordinator.invalidateHighlightingAfterExternalChange(force: force)
        }

        /// An edit through the real path: mutate the storage, then hand the
        /// coordinator the notification AppKit would have delivered.
        func applyEdit(range: NSRange, with replacement: String) {
            storage.replaceCharacters(in: range, with: replacement)
            coordinator.textDidChange(
                Notification(name: NSText.didChangeNotification, object: textView)
            )
        }

        /// `refresh` fills the status bar on a tab switch; `push` on every
        /// selection change. U8: they must count the same thing.
        func refreshCounts() -> Int {
            coordinator.refresh(textView: textView, cursor: cursor)
            return cursor.totalCount
        }

        func pushCounts() -> Int {
            coordinator.push(from: textView)
            return cursor.totalCount
        }

        func pushPosition(at location: Int) -> (line: Int, column: Int) {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            coordinator.push(from: textView)
            return (cursor.line, cursor.column)
        }

        /// Every character's foreground colour, for attribute equality checks.
        func foregroundColors() -> [NSColor?] {
            (0..<storage.length).map {
                storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor
            }
        }
    }
}
#endif
