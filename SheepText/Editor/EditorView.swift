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
        .onChange(of: left.text) { _, _ in
            guard !isLargeCompare else {
                diffCounts = .zero
                return
            }
            scheduleDiffCounts()
        }
        .onChange(of: right.text) { _, _ in
            guard !isLargeCompare else {
                diffCounts = .zero
                return
            }
            scheduleDiffCounts()
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

    private func scheduleDiffCounts() {
        diffCountsTask?.cancel()
        guard !isLargeCompare else {
            diffCounts = .zero
            return
        }
        let leftText = left.text
        let rightText = right.text
        let delay = CompareEngine.liveEditDelay(leftText: leftText, rightText: rightText)
        diffCountsTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let counts = await Task.detached(priority: .utility) {
                CompareDiffCounter.make(leftText: leftText, rightText: rightText)
            }.value
            guard !Task.isCancelled else { return }
            diffCounts = counts
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
        var r = 0; var a = 0; var c = 0; var m = 0
        for row in CompareEngine.buildRows(leftText: leftText, rightText: rightText, mode: .liveEdit) {
            switch row.kind {
            case .leftOnly:  r += 1
            case .rightOnly: a += 1
            case .changed:   c += 1
            case .moved:     m += 1
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
}

nonisolated private enum CompareBuildMode: Sendable {
    case detailed
    case liveEdit
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
    let paragraphRanges: [NSRange]
    let wordHighlightRanges: [NSRange]
}

nonisolated private enum SavedLineMarkStyle: Sendable {
    case added
    case modified
}

nonisolated private enum CompareEngine {
    private static let liveEditLineProductLimit = 180_000

    /// `buildRows` is a pure function of (leftText, rightText, mode), and every
    /// keystroke in compare mode asks for the same answer three times: once per
    /// pane to rebuild the display, and once more for the header's diff counts.
    /// Memoising the last result per mode lets those three share a single diff.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [CompareBuildMode: (left: String, right: String, rows: [CompareRow])] = [:]

    /// Called when a pane leaves compare mode so two whole documents are not
    /// held alive by the cache.
    static func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    static func buildRows(
        leftText: String,
        rightText: String,
        mode: CompareBuildMode = .detailed
    ) -> [CompareRow] {
        cacheLock.lock()
        let hit = cache[mode]
        cacheLock.unlock()
        if let hit, hit.left == leftText, hit.right == rightText {
            return hit.rows
        }

        let rows = computeRows(leftText: leftText, rightText: rightText, mode: mode)

        cacheLock.lock()
        cache[mode] = (leftText, rightText, rows)
        cacheLock.unlock()
        return rows
    }

    private static func computeRows(
        leftText: String,
        rightText: String,
        mode: CompareBuildMode
    ) -> [CompareRow] {
        var opts = CompareOptions()
        opts.ignoreCase = false
        opts.ignoreChangedSpaces = false
        opts.shiftBoundaries = true
        opts.detectCharDiffs = true
        // changedResemblPercent uses CompareOptions default (50 %)

        // Must use the same splitter as LineHashing.extractLines, or the line
        // numbers coming back from TextComparator index a different array.
        let linesA = LineHashing.splitLines(leftText)
        let linesB = LineHashing.splitLines(rightText)

        if mode == .liveEdit, shouldUseFastLiveRows(leftCount: linesA.count, rightCount: linesB.count) {
            return fastLiveRows(linesA: linesA, linesB: linesB, options: opts)
        }

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
        let leftCount = estimatedLineCount(leftText)
        let rightCount = estimatedLineCount(rightText)
        if shouldUseFastLiveRows(leftCount: leftCount, rightCount: rightCount) { return 0.40 }
        let total = leftCount + rightCount
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
                            kind: matchedLineKind(leftLineNumber: aLine, rightLineNumber: bLine)
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

    private static func shouldUseFastLiveRows(leftCount: Int, rightCount: Int) -> Bool {
        leftCount * rightCount > liveEditLineProductLimit
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

    private static func fastLiveRows(
        linesA: [String],
        linesB: [String],
        options: CompareOptions
    ) -> [CompareRow] {
        // Compare NORMALISED lines, not raw ones. Raw comparison meant a file
        // whose twin used the other line ending matched nothing at all — every
        // line on the CRLF side carries a trailing "\r" — so the moment a file
        // was large enough to take this fast path, typing painted the entire
        // document red on the left and green on the right. The rows still carry
        // the raw text, which is what gets displayed.
        let normA = linesA.map { LineHashing.normalize($0, options: options) }
        let normB = linesB.map { LineHashing.normalize($0, options: options) }

        var rows: [CompareRow] = []
        let aCount = linesA.count
        let bCount = linesB.count
        rows.reserveCapacity(max(aCount, bCount))

        var prefix = 0
        while prefix < aCount && prefix < bCount && normA[prefix] == normB[prefix] {
            rows.append(
                CompareRow(
                    leftLineNumber: prefix + 1,
                    leftText: linesA[prefix],
                    rightLineNumber: prefix + 1,
                    rightText: linesB[prefix],
                    kind: .same
                )
            )
            prefix += 1
        }

        var suffix = 0
        while suffix < (aCount - prefix),
              suffix < (bCount - prefix),
              normA[aCount - 1 - suffix] == normB[bCount - 1 - suffix] {
            suffix += 1
        }

        let aMiddleEnd = aCount - suffix
        let bMiddleEnd = bCount - suffix
        let middleCount = max(aMiddleEnd - prefix, bMiddleEnd - prefix)
        for offset in 0..<middleCount {
            let aIndex = prefix + offset
            let bIndex = prefix + offset
            let leftText = aIndex < aMiddleEnd ? linesA[aIndex] : nil
            let rightText = bIndex < bMiddleEnd ? linesB[bIndex] : nil
            let kind: CompareRow.Kind
            if leftText != nil, rightText != nil {
                kind = normA[aIndex] == normB[bIndex] ? .same : .changed
            } else {
                kind = leftText == nil ? .rightOnly : .leftOnly
            }
            rows.append(
                CompareRow(
                    leftLineNumber: leftText == nil ? nil : aIndex + 1,
                    leftText: leftText,
                    rightLineNumber: rightText == nil ? nil : bIndex + 1,
                    rightText: rightText,
                    kind: kind
                )
            )
        }

        if suffix > 0 {
            for offset in stride(from: suffix - 1, through: 0, by: -1) {
                let aIndex = aCount - 1 - offset
                let bIndex = bCount - 1 - offset
                rows.append(
                    CompareRow(
                        leftLineNumber: aIndex + 1,
                        leftText: linesA[aIndex],
                        rightLineNumber: bIndex + 1,
                        rightText: linesB[bIndex],
                        kind: matchedLineKind(leftLineNumber: aIndex + 1, rightLineNumber: bIndex + 1)
                    )
                )
            }
        }

        return rows
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

    private static func matchedLineKind(leftLineNumber: Int, rightLineNumber: Int) -> CompareRow.Kind {
        // Matched lines are always .same; genuinely moved lines are detected separately
        // by detectMovedRows (which looks for leftOnly content matching a rightOnly line).
        // Comparing line numbers here incorrectly marks every post-insertion match as .moved.
        .same
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

    private static func detectMovedRows(in rows: [CompareRow], options: CompareOptions) -> [CompareRow] {
        var rightBuckets: [String: [Int]] = [:]
        for (idx, row) in rows.enumerated() where row.kind == .rightOnly {
            guard let text = row.rightText else { continue }
            let key = normalizeForMove(text, options: options)
            rightBuckets[key, default: []].append(idx)
        }

        var consumedRight = Set<Int>()
        var result: [CompareRow] = []
        result.reserveCapacity(rows.count)

        // Per-key cursor rather than trimming the bucket in place: pulling the
        // array out of the dictionary with `var` forces a copy-on-write copy,
        // and writing it back copies again, so a file with many identical lines
        // (configs are full of them) made this quadratic in the bucket size.
        var bucketCursor: [String: Int] = [:]

        for (idx, row) in rows.enumerated() {
            if row.kind == .leftOnly, let leftText = row.leftText {
                let key = normalizeForMove(leftText, options: options)
                if let candidates = rightBuckets[key] {
                    var k = bucketCursor[key] ?? 0
                    while k < candidates.count, consumedRight.contains(candidates[k]) { k += 1 }
                    bucketCursor[key] = k
                    if k < candidates.count {
                        let matchIdx = candidates[k]
                        consumedRight.insert(matchIdx)
                        let r = rows[matchIdx]
                        result.append(
                            CompareRow(
                                leftLineNumber: row.leftLineNumber,
                                leftText: row.leftText,
                                rightLineNumber: r.rightLineNumber,
                                rightText: r.rightText,
                                kind: .moved
                            )
                        )
                        continue
                    }
                }
            }

            if row.kind == .rightOnly, consumedRight.contains(idx) {
                continue
            }
            result.append(row)
        }

        return result
    }

    private static func normalizeForMove(_ text: String, options: CompareOptions) -> String {
        LineHashing.normalize(text, options: options)
    }
}

private struct SafePlainEditor: View {
    @Environment(DocumentStore.self) private var documents
    @Environment(AppPreferences.self) private var preferences
    let document: Document

    var body: some View {
        TextEditor(
            text: Binding(
                get: { document.text },
                set: { newValue in
                    document.text = newValue
                    document.isDirty = true
                    documents.scheduleDraftSave(for: document.id)
                    documents.scheduleAutoSave(
                        for: document.id,
                        isEnabled: preferences.autoSaveEnabled,
                        delay: preferences.autoSaveDelay
                    )
                }
            )
        )
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(Color(nsColor: .bestTextEditorForeground))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .bestTextEditorBackground))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                let folding = context.coordinator.foldingManager
                let storage = textView.textStorage
                let viewText = storage.map { folding.fullText(from: $0) } ?? textView.string
                if viewText != document.text {
                    // The storage is about to be replaced wholesale, so the regions
                    // describe text that no longer exists.
                    folding.discardRegions()
                    textView.discardUndoHistory()
                    textView.string = document.text
                    textView.applyDocumentVisualSettings()
                    context.coordinator.applyHighlight(to: textView, document: document)
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
        private var compareTransferObserver: NSObjectProtocol?
        private var documentReloadObserver: NSObjectProtocol?
        private var documentSaveObserver: NSObjectProtocol?
        private weak var cursorState: CursorState?
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

        private struct SyntaxHighlightCacheEntry {
            let language: String
            let isDark: Bool
            let utf16Length: Int
            let textHash: Int
            let result: NSAttributedString
        }

        private static var syntaxHighlightCache: [Document.ID: SyntaxHighlightCacheEntry] = [:]
        private static var syntaxHighlightCacheOrder: [Document.ID] = []
        private static let syntaxHighlightCacheLimit = 32

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
                        documentReloadObserver, documentSaveObserver, scrollBoundsObserver, scrollSyncObserver,
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
                guard let self, let tv = self.boundTextView as? EditorTextView else { return }
                // Theme colors changed — cached highlight results are stale.
                Self.syntaxHighlightCache.removeAll()
                Self.syntaxHighlightCacheOrder.removeAll()
                tv.applyDocumentVisualSettings()
                self.applyHighlight(to: tv, document: self.document)
            }

            editorAppearanceObserver = NotificationCenter.default.addMainActorObserver(
                forName: .editorAppearanceDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.invalidateHighlightingAfterExternalChange()
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
                self.applyCompareDisplay(to: tv, document: self.document, mode: .liveEdit)
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
                    self.applyCompareDisplay(
                        to: textView,
                        document: self.document,
                        mode: self.isLargeCompareContext ? .liveEdit : .detailed
                    )
                    return
                }

                // Same reason as in updateNSView: the storage is replaced wholesale, so
                // any fold region left behind would duplicate its block into document.text.
                self.foldingManager.discardRegions()
                textView.discardUndoHistory()
                textView.string = self.document.text
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
                scrollBoundsObserver = NotificationCenter.default.addMainActorObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: sv.contentView,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, !self.isSyncScrolling, self.comparePeer != nil else { return }
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
            if peer == nil { CompareEngine.clearCache() }
            let peerID = peer?.id
            let changed = peerID != lastComparePeerID || side != lastCompareSide
            if changed, peer != nil, !foldingManager.regions.isEmpty {
                // Switching into compare: the storage is about to be replaced by display
                // text, so these regions would describe characters that no longer exist.
                if let storage = boundTextView?.textStorage {
                    foldingManager.saveFolds(for: document.id.uuidString)
                    foldingManager.unfoldAll(in: storage)
                }
                foldingManager.discardRegions()
            }
            comparePeer = peer
            compareSide = side
            lastComparePeerID = peerID
            lastCompareSide = side
            return changed
        }

        func refresh(textView: NSTextView, cursor: CursorState) {
            let total = (textView.textStorage?.string ?? textView.string).count
            cursor.line          = 1
            cursor.column        = 1
            cursor.selectedCount = 0
            cursor.totalCount    = total
        }

        private func push(from textView: NSTextView) {
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
            let position = TextLineIndex.lineColumn(in: str, at: loc)

            cursorState.line = position.line
            cursorState.column = position.column
            cursorState.selectedCount = selected.length
            cursorState.totalCount = totalCount
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            guard !isApplyingCompare else { return }
            guard !foldingManager.isMutating else { return }
            guard let storage = tv.textStorage else { return }

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
                let editedLine = TextLineIndex.lineNumber(in: displayStr, at: safeLoc)
                editedLines.insert(editedLine)
                boundGutter?.editedLines = editedLines

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
            document.precomputedSyntaxHighlight = nil
            if !isFoldMutation {
                document.isDirty = true
                scheduleSafetySaves(for: document, textView: tv)
            }
            push(from: tv)
            if comparePeer != nil {
                NotificationCenter.default.post(name: .compareDocumentsDidChange, object: nil)
            }

            scheduleSavedLineMarks()

            if isFoldMutation {
                return
            }
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
        func invalidateHighlightingAfterExternalChange() {
            guard let tv = boundTextView as? EditorTextView else { return }
            Self.syntaxHighlightCache.removeAll()
            Self.syntaxHighlightCacheOrder.removeAll()
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

        /// Reapply highlight attributes to the whole document. Called on
        /// initial load and on tab switches (via refresh).
        func applyHighlight(to textView: NSTextView, document: Document) {
            if textView.hasMarkedText() {
                return
            }
            textView.backgroundColor = .editorBackground
            textView.enclosingScrollView?.backgroundColor = .editorBackground
            if let editor = textView as? EditorTextView {
                textView.textColor = editor.editorForegroundColor
                textView.insertionPointColor = editor.editorForegroundColor
            } else {
                textView.textColor = .editorForeground
                textView.insertionPointColor = .editorForeground
            }
            let baseAttributes = (textView as? EditorTextView)?.editorBaseAttributes()
                ?? [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.editorForeground,
                    .ligature: 1
                ]
            textView.typingAttributes = baseAttributes

            // In compare mode, build filler-aligned display text and skip syntax highlighting.
            if let editor = textView as? EditorTextView, comparePeer != nil {
                applyCompareDisplay(
                    to: editor,
                    document: document,
                    mode: isLargeCompareContext ? .liveEdit : .detailed
                )
                return
            }

            guard let storage = textView.textStorage else { return }

            let displayLength = storage.length
            guard displayLength > 0 else { return }

            if document.isLargeFileModeActive {
                resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                return
            }

            let sourceText = foldingManager.fullText(from: storage)
            let isDark = (textView as? EditorTextView)?.preferences?.isDarkHighlight(for: textView.effectiveAppearance)
                ?? (textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let resolvedLanguage = HighlightOverrides.shared.resolvedLanguage(
                for: document.url,
                defaultLanguage: document.language
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
                storage: storage,
                baseAttributes: baseAttributes,
                language: resolvedLanguage,
                isDark: isDark,
                sourceLength: sourceLength,
                sourceHash: sourceHash
            ) {
                return
            }

            highlightGeneration += 1
            let currentGeneration = highlightGeneration

            SyntaxEngine.shared.highlight(
                text: sourceText,
                language: resolvedLanguage,
                isDark: isDark,
                documentID: document.id
            ) { [weak self, weak textView] result, changedRanges, _ in
                guard
                    let self,
                    let textView,
                    self.highlightGeneration == currentGeneration,
                    self.boundTextView === textView,
                    let storage = textView.textStorage
                else { return }

                if let result {
                    Self.storeSyntaxHighlight(
                        SyntaxHighlightCacheEntry(
                            language: resolvedLanguage,
                            isDark: isDark,
                            utf16Length: sourceLength,
                            textHash: sourceHash,
                            result: result
                        ),
                        for: document.id
                    )
                    self.applySyntaxResult(
                        result,
                        to: storage,
                        baseAttributes: baseAttributes,
                        changedRanges: changedRanges
                    )
                } else {
                    Self.storeSyntaxHighlight(nil, for: document.id)
                    self.resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                }
            }
        }

        func applyCachedHighlightOrDefer(to textView: NSTextView, document: Document) {
            deferredHighlightWorkItem?.cancel()
            applyEditorBaseColors(to: textView)

            let baseAttributes = (textView as? EditorTextView)?.editorBaseAttributes()
                ?? [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.editorForeground,
                    .ligature: 1
                ]
            textView.typingAttributes = baseAttributes
            guard comparePeer == nil, let storage = textView.textStorage, storage.length > 0 else {
                applyHighlight(to: textView, document: document)
                return
            }

            if document.isLargeFileModeActive {
                resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                return
            }

            let sourceText = foldingManager.fullText(from: storage)
            let isDark = (textView as? EditorTextView)?.preferences?.isDarkHighlight(for: textView.effectiveAppearance)
                ?? (textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let resolvedLanguage = HighlightOverrides.shared.resolvedLanguage(
                for: document.url,
                defaultLanguage: document.language
            )
            let sourceLength = (sourceText as NSString).length
            let sourceHash = sourceText.hashValue

            if applyPreparedHighlightIfAvailable(
                to: textView,
                document: document,
                storage: storage,
                baseAttributes: baseAttributes,
                language: resolvedLanguage,
                isDark: isDark,
                sourceLength: sourceLength,
                sourceHash: sourceHash
            ) {
                return
            }

            applyVisibleHighlight(
                to: textView,
                document: document,
                storage: storage,
                baseAttributes: baseAttributes,
                language: resolvedLanguage,
                isDark: isDark
            )
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView, self.document.id == document.id else { return }
                self.applyHighlight(to: textView, document: document)
            }
            deferredHighlightWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }

        func applyPreparedHighlightIfAvailable(to textView: NSTextView, document: Document) -> Bool {
            applyEditorBaseColors(to: textView)
            let baseAttributes = (textView as? EditorTextView)?.editorBaseAttributes()
                ?? [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.editorForeground,
                    .ligature: 1
                ]
            textView.typingAttributes = baseAttributes
            guard comparePeer == nil,
                  !document.isLargeFileModeActive,
                  let storage = textView.textStorage,
                  storage.length > 0
            else { return false }

            let sourceText = foldingManager.fullText(from: storage)
            let isDark = (textView as? EditorTextView)?.preferences?.isDarkHighlight(for: textView.effectiveAppearance)
                ?? (textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let resolvedLanguage = HighlightOverrides.shared.resolvedLanguage(
                for: document.url,
                defaultLanguage: document.language
            )
            return applyPreparedHighlightIfAvailable(
                to: textView,
                document: document,
                storage: storage,
                baseAttributes: baseAttributes,
                language: resolvedLanguage,
                isDark: isDark,
                sourceLength: (sourceText as NSString).length,
                sourceHash: sourceText.hashValue
            )
        }

        private func applyPreparedHighlightIfAvailable(
            to textView: NSTextView,
            document: Document,
            storage: NSTextStorage,
            baseAttributes: [NSAttributedString.Key: Any],
            language: String,
            isDark: Bool,
            sourceLength: Int,
            sourceHash: Int
        ) -> Bool {
            if let cached = Self.syntaxHighlightCache[document.id],
               cached.language == language,
               cached.isDark == isDark,
               cached.utf16Length == sourceLength,
               cached.textHash == sourceHash,
               cached.result.length == sourceLength {
                applySyntaxResult(cached.result, to: storage, baseAttributes: baseAttributes)
                return true
            }

            if let precomputed = document.precomputedSyntaxHighlight,
               precomputed.language == language,
               precomputed.isDark == isDark,
               precomputed.utf16Length == sourceLength,
               precomputed.textHash == sourceHash,
               precomputed.result.length == sourceLength {
                Self.storeSyntaxHighlight(
                    SyntaxHighlightCacheEntry(
                        language: precomputed.language,
                        isDark: precomputed.isDark,
                        utf16Length: precomputed.utf16Length,
                        textHash: precomputed.textHash,
                        result: precomputed.result
                    ),
                    for: document.id
                )
                document.precomputedSyntaxHighlight = nil
                applySyntaxResult(precomputed.result, to: storage, baseAttributes: baseAttributes)
                return true
            }

            return false
        }

        private func applyVisibleHighlight(
            to textView: NSTextView,
            document: Document,
            storage: NSTextStorage,
            baseAttributes: [NSAttributedString.Key: Any],
            language: String,
            isDark: Bool
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
            storage.setAttributes(baseAttributes, range: range)
            let documentID = document.id
            SyntaxEngine.shared.highlightSnapshot(
                text: visibleText,
                language: language,
                isDark: isDark
            ) { [weak self, weak textView, weak storage] result, _ in
                guard let self,
                      let textView,
                      let storage,
                      self.document.id == documentID,
                      self.boundTextView === textView,
                      NSMaxRange(range) <= storage.length,
                      storage.string == textView.string,
                      let result
                else { return }

                self.applySyntaxResult(
                    result,
                    to: storage,
                    displayRange: range,
                    baseAttributes: baseAttributes
                )
            }
        }

        private func visibleParagraphRange(in textView: NSTextView) -> NSRange? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let storage = textView.textStorage,
                  storage.length > 0
            else { return nil }

            let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
            let queryRect = visibleRect.offsetBy(
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
            return (storage.string as NSString).paragraphRange(for: charRange)
        }

        private func applyEditorBaseColors(to textView: NSTextView) {
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
            document: Document,
            mode: CompareBuildMode = .detailed
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
            let savedRealLoc    = realTextOffset(for: savedDisplayLoc, in: storage, lineInfos: currentLineInfos)

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

                // Heavy diff + build entirely off the main thread.
                let rows = CompareEngine.buildRows(leftText: leftText, rightText: rightText, mode: mode)
                guard generation.isCurrent(thisVersion) else { return }

                let (displayText, lineInfos) = CompareDisplayBuilder.build(rows: rows, side: side)
                guard generation.isCurrent(thisVersion) else { return }

                // Range calculation remains off the main thread, but AppKit
                // colors and attributed strings are materialized on MainActor.
                // The ranges come only from displayText and lineInfos, both of
                // which already exist here — so this walks the paragraphs off the
                // main thread. It used to run inside the main-queue block, which
                // meant ~1200 paragraphRange calls per rebuild on the main thread.
                var paragraphRanges: [NSRange] = []
                var wordHighlightRanges: [NSRange] = []
                paragraphRanges.reserveCapacity(lineInfos.count)
                let nsDisplay = displayText as NSString
                var hIdx = 0
                for info in lineInfos {
                    let paraRange = nsDisplay.paragraphRange(for: NSRange(location: hIdx, length: 0))
                    paragraphRanges.append(paraRange)
                    for relRange in info.charHighlights {
                        let absLoc = paraRange.location + relRange.location
                        let absEnd = min(absLoc + relRange.length, NSMaxRange(paraRange) - 1)
                        if absEnd > absLoc {
                            wordHighlightRanges.append(
                                NSRange(location: absLoc, length: absEnd - absLoc)
                            )
                        }
                    }
                    let next = NSMaxRange(paraRange)
                    if next <= hIdx { break }
                    hIdx = next
                }
                let snapshot = CompareLayoutSnapshot(
                    displayText: displayText,
                    lineInfos: lineInfos,
                    paragraphRanges: paragraphRanges,
                    wordHighlightRanges: wordHighlightRanges
                )
                guard generation.isCurrent(thisVersion) else { return }

                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView,
                          let storage = textView.textStorage,
                          generation.isCurrent(thisVersion) else { return }

                    let ns = NSMutableAttributedString(
                        string: snapshot.displayText,
                        attributes: textView.editorBaseAttributes()
                    )
                    for (info, paraRange) in zip(snapshot.lineInfos, snapshot.paragraphRanges)
                    where info.isFiller {
                        ns.addAttribute(.isFillerLine, value: true, range: paraRange)
                    }

                    let lineHighlights = zip(snapshot.lineInfos, snapshot.paragraphRanges).compactMap {
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
                        let newDisplayLoc = self.displayOffset(
                            for: savedRealLoc,
                            in: storage,
                            lineInfos: snapshot.lineInfos
                        )
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
                  NSMaxRange(displayRows) <= currentLineInfos.count
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

            let realLines = (displayRows.location ..< NSMaxRange(displayRows))
                .compactMap { infos[$0].realLineNumber }

            let replaceStart: Int
            let replaceCount: Int
            if let first = realLines.first, let last = realLines.last {
                replaceStart = first - 1
                replaceCount = last - first + 1
            } else {
                var anchor = 0
                var idx = displayRows.location - 1
                while idx >= 0 {
                    if let real = infos[idx].realLineNumber { anchor = real; break }
                    idx -= 1
                }
                replaceStart = anchor
                replaceCount = 0
            }
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
                applyCompareDisplay(to: tv, document: document,
                                    mode: isLargeCompareContext ? .liveEdit : .detailed)
            }
            NotificationCenter.default.post(
                name: .compareDocumentsDidChange,
                object: nil,
                userInfo: ["documentID": document.id]
            )
        }

        /// Convert a display-text character offset to a real-text character offset
        /// by skipping filler line characters.
        private func realTextOffset(for displayLoc: Int, in storage: NSTextStorage, lineInfos: [CompareLineInfo]) -> Int {
            guard storage.length > 0 else { return 0 }
            let ns = storage.string as NSString
            var realCount = 0
            var displayCount = 0
            var idx = 0
            var lineIdx = 0
            while idx < ns.length {
                let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
                let isFiller = lineIdx < lineInfos.count ? lineInfos[lineIdx].isFiller : false
                let paraLen = paraRange.length
                if displayCount + paraLen > displayLoc {
                    // Cursor is inside this paragraph.
                    if !isFiller { realCount += displayLoc - displayCount }
                    break
                }
                if !isFiller { realCount += paraLen }
                displayCount += paraLen
                lineIdx += 1
                let next = NSMaxRange(paraRange)
                if next <= idx { break }
                idx = next
            }
            return realCount
        }

        /// Convert a real-text character offset back to a display-text offset,
        /// adding filler line lengths.
        private func displayOffset(for realLoc: Int, in storage: NSTextStorage, lineInfos: [CompareLineInfo]) -> Int {
            guard storage.length > 0 else { return 0 }
            let ns = storage.string as NSString
            var realCount = 0
            var displayCount = 0
            var idx = 0
            var lineIdx = 0
            while idx < ns.length {
                let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
                let isFiller = lineIdx < lineInfos.count ? lineInfos[lineIdx].isFiller : false
                let paraLen = paraRange.length
                if !isFiller {
                    if realCount + paraLen > realLoc {
                        return displayCount + (realLoc - realCount)
                    }
                    realCount += paraLen
                }
                displayCount += paraLen
                lineIdx += 1
                let next = NSMaxRange(paraRange)
                if next <= idx { break }
                idx = next
            }
            return min(displayCount, storage.length)
        }

        private func removeFillerLines(from storage: NSTextStorage) {
            let ns = storage.string as NSString
            var ranges: [NSRange] = []
            var idx = 0
            while idx < ns.length {
                let paraRange = ns.paragraphRange(for: NSRange(location: idx, length: 0))
                if storage.attribute(.isFillerLine, at: paraRange.location, effectiveRange: nil) != nil {
                    ranges.append(paraRange)
                }
                let next = NSMaxRange(paraRange)
                if next <= idx { break }
                idx = next
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
                let baseAttributes = (textView as? EditorTextView)?.editorBaseAttributes()
                    ?? [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: NSColor.editorForeground,
                        .ligature: 1
                    ]
                if let storage = textView.textStorage {
                    resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                }
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
                self.applyCompareDisplay(to: textView, document: document, mode: .liveEdit)
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
                    }
                }
            }
        }

        nonisolated private static func computeSavedLineMarks(
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

        private func applyHighlightedAttributes(
            _ attrs: [NSAttributedString.Key: Any],
            fullRange: NSRange,
            to storage: NSTextStorage,
            segments: [(full: NSRange, display: NSRange)],
            fallbackFont: NSFont
        ) {
            var merged = attrs
            let highlightedFont = merged[.font] as? NSFont
            merged[.font] = normalizedFont(from: highlightedFont, fallback: fallbackFont)

            for segment in segments {
                let intersection = NSIntersectionRange(fullRange, segment.full)
                guard intersection.length > 0 else { continue }

                let delta = intersection.location - segment.full.location
                let displayRange = NSRange(
                    location: segment.display.location + delta,
                    length: intersection.length
                )
                storage.addAttributes(merged, range: displayRange)
            }
        }

        private func normalizedFont(from highlighted: NSFont?, fallback: NSFont) -> NSFont {
            guard let highlighted else { return fallback }

            let traits = highlighted.fontDescriptor.symbolicTraits
            let descriptor = fallback.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: fallback.pointSize) ?? fallback
        }

        private func applySyntaxResult(
            _ result: NSAttributedString,
            to storage: NSTextStorage,
            baseAttributes: [NSAttributedString.Key: Any],
            changedRanges: [NSRange]? = nil
        ) {
            let displayRange = NSRange(location: 0, length: storage.length)
            guard displayRange.length > 0 else { return }

            if let changedRanges,
               foldingManager.regions.isEmpty,
               result.length == storage.length {
                let changedLength = changedRanges.reduce(0) { $0 + $1.length }
                if changedLength == 0 { return }
                if changedLength < max(1, storage.length / 2) {
                    applySyntaxResult(
                        result,
                        to: storage,
                        changedRanges: changedRanges,
                        baseAttributes: baseAttributes
                    )
                    return
                }
            }

            let segments = visibleSegments(in: storage)
            guard !segments.isEmpty else {
                resetHighlightAttributes(in: storage, baseAttributes: baseAttributes)
                return
            }

            let highlightedRange = NSRange(location: 0, length: result.length)
            let fallbackFont = (baseAttributes[.font] as? NSFont)
                ?? NSFont.systemFont(ofSize: 13)

            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: displayRange)
            result.enumerateAttributes(in: highlightedRange, options: []) { attrs, fullRange, _ in
                guard fullRange.length > 0 else { return }
                self.applyHighlightedAttributes(
                    attrs,
                    fullRange: fullRange,
                    to: storage,
                    segments: segments,
                    fallbackFont: fallbackFont
                )
            }
            storage.endEditing()
            applyThaiFontFallback(to: storage, range: displayRange)
        }

        /// Incremental counterpart of the full-document apply above. NSTextStorage
        /// already shifts unchanged attributes with each edit, so only paragraphs
        /// invalidated by Tree-sitter need to be cleared and repainted.
        private func applySyntaxResult(
            _ result: NSAttributedString,
            to storage: NSTextStorage,
            changedRanges: [NSRange],
            baseAttributes: [NSAttributedString.Key: Any]
        ) {
            let fallbackFont = (baseAttributes[.font] as? NSFont)
                ?? NSFont.systemFont(ofSize: 13)

            storage.beginEditing()
            for range in changedRanges {
                guard range.location != NSNotFound,
                      range.length > 0,
                      NSMaxRange(range) <= storage.length
                else { continue }

                storage.setAttributes(baseAttributes, range: range)
                result.enumerateAttributes(in: range, options: []) { attrs, tokenRange, _ in
                    guard tokenRange.length > 0, !attrs.isEmpty else { return }
                    var merged = attrs
                    let highlightedFont = merged[.font] as? NSFont
                    merged[.font] = self.normalizedFont(from: highlightedFont, fallback: fallbackFont)
                    storage.addAttributes(merged, range: tokenRange)
                }
            }
            storage.endEditing()
            for range in changedRanges {
                if NSMaxRange(range) <= storage.length {
                    applyThaiFontFallback(to: storage, range: range)
                }
            }
        }

        private func applySyntaxResult(
            _ result: NSAttributedString,
            to storage: NSTextStorage,
            displayRange: NSRange,
            baseAttributes: [NSAttributedString.Key: Any]
        ) {
            guard displayRange.length > 0,
                  NSMaxRange(displayRange) <= storage.length
            else { return }

            let highlightedRange = NSRange(location: 0, length: result.length)
            let fallbackFont = (baseAttributes[.font] as? NSFont)
                ?? NSFont.systemFont(ofSize: 13)

            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: displayRange)
            result.enumerateAttributes(in: highlightedRange, options: []) { attrs, localRange, _ in
                guard localRange.length > 0 else { return }
                let targetRange = NSRange(
                    location: displayRange.location + localRange.location,
                    length: min(localRange.length, displayRange.length - localRange.location)
                )
                guard targetRange.length > 0,
                      NSMaxRange(targetRange) <= NSMaxRange(displayRange)
                else { return }

                var merged = attrs
                let highlightedFont = merged[.font] as? NSFont
                merged[.font] = self.normalizedFont(from: highlightedFont, fallback: fallbackFont)
                storage.addAttributes(merged, range: targetRange)
            }
            storage.endEditing()
            applyThaiFontFallback(to: storage, range: displayRange)
        }

        private func resetHighlightAttributes(
            in storage: NSTextStorage,
            baseAttributes: [NSAttributedString.Key: Any]
        ) {
            let range = NSRange(location: 0, length: storage.length)
            guard range.length > 0 else { return }
            storage.beginEditing()
            storage.setAttributes(baseAttributes, range: range)
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

    static func build(
        rows: [CompareRow],
        side: ComparePaneSide
    ) -> (displayText: String, lineInfos: [CompareLineInfo]) {
        var lines: [String] = []
        var infos: [CompareLineInfo] = []

        for row in rows {
            let isLeft = side == .left
            let text: String?
            let realLine: Int?
            let isFiller: Bool
            let mapped: Int?

            switch row.kind {
            case .same:
                text     = isLeft ? row.leftText  : row.rightText
                realLine = isLeft ? row.leftLineNumber : row.rightLineNumber
                isFiller = false
                mapped   = nil

            case .changed:
                text     = isLeft ? row.leftText  : row.rightText
                realLine = isLeft ? row.leftLineNumber : row.rightLineNumber
                isFiller = (text == nil)
                mapped   = nil

            case .leftOnly:
                if isLeft {
                    text     = row.leftText;  realLine = row.leftLineNumber;  isFiller = false; mapped = nil
                } else {
                    text     = nil;           realLine = nil;                 isFiller = true;  mapped = nil
                }

            case .rightOnly:
                if isLeft {
                    text     = nil;            realLine = nil;                isFiller = true;  mapped = nil
                } else {
                    text     = row.rightText;  realLine = row.rightLineNumber; isFiller = false; mapped = nil
                }

            case .paired:
                if isLeft {
                    if row.leftText != nil {
                        text = row.leftText; realLine = row.leftLineNumber; isFiller = false; mapped = nil
                    } else {
                        text = nil; realLine = nil; isFiller = true; mapped = nil
                    }
                } else {
                    if row.rightText != nil {
                        text = row.rightText; realLine = row.rightLineNumber; isFiller = false; mapped = nil
                    } else {
                        text = nil; realLine = nil; isFiller = true; mapped = nil
                    }
                }

            case .moved:
                text     = isLeft ? row.leftText  : row.rightText
                realLine = isLeft ? row.leftLineNumber : row.rightLineNumber
                isFiller = false
                mapped   = isLeft ? row.rightLineNumber : row.leftLineNumber
            }

            let sym      = symbol(for: row.kind, side: side, isFiller: isFiller)
            let style    = style(for: row.kind, side: side, isFiller: isFiller)
            let charHLs  = isFiller ? [] : charHighlights(row: row, myText: text, side: side)

            lines.append(isFiller ? "" : (text ?? ""))
            infos.append(CompareLineInfo(
                realLineNumber: realLine,
                isFiller: isFiller,
                gutterSymbol: sym,
                style: style,
                mappedLineNumber: mapped,
                charHighlights: charHLs
            ))
        }

        // Join lines with newlines; add trailing newline so last paragraph is complete.
        let displayText = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        return (displayText, infos)
    }

    // MARK: - Word-level diff

    private struct WordToken: Sendable {
        let utf16Offset: Int
        let utf16Length: Int
        let text: String
    }

    /// Splits `string` into word tokens (alphanumeric/underscore runs) and single-char separators.
    private static func tokenize(_ string: String) -> [WordToken] {
        let ns = string as NSString
        let len = ns.length
        var tokens: [WordToken] = []
        var i = 0
        while i < len {
            let c = ns.character(at: i)
            if isWordChar(c) {
                var j = i + 1
                while j < len && isWordChar(ns.character(at: j)) { j += 1 }
                tokens.append(WordToken(utf16Offset: i, utf16Length: j - i,
                                        text: ns.substring(with: NSRange(location: i, length: j - i))))
                i = j
            } else {
                tokens.append(WordToken(utf16Offset: i, utf16Length: 1,
                                        text: ns.substring(with: NSRange(location: i, length: 1))))
                i += 1
            }
        }
        return tokens
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
    }

    /// Returns word-level diff highlights (relative to line start).
    /// Adjacent changed word-tokens are merged into one background span.
    private static func charHighlights(
        row: CompareRow,
        myText: String?,
        side: ComparePaneSide
    ) -> [NSRange] {
        guard let mine = myText else { return [] }
        let other: String?
        switch (row.kind, side) {
        case (.changed, .left), (.paired, .left):
            other = row.rightText
        case (.changed, .right), (.paired, .right):
            other = row.leftText
        default: return []
        }
        guard let theOther = other else { return [] }
        guard mine != theOther else { return [] }

        let mineTokens  = tokenize(mine)
        let otherTokens = tokenize(theOther)
        guard !mineTokens.isEmpty,
              !otherTokens.isEmpty,
              mineTokens.count <= wordDiffTokenLimit,
              otherTokens.count <= wordDiffTokenLimit,
              mineTokens.count * otherTokens.count <= wordDiffTokenProductLimit
        else { return [] }

        let ops = DiffCalc.diff(mineTokens, otherTokens) { $0.text == $1.text }
        // .changed rows already passed char-level resemblance — always show word highlights.
        // .paired rows need a minimum similarity to avoid noisy highlights on unrelated lines.
        if row.kind == .paired {
            guard similarityPercent(from: ops) >= pairedWordDiffThreshold else { return [] }
        }

        // Collect .onlyInA tokens (words present in mine but not other), merging adjacent spans.
        var result: [NSRange] = []
        var runStart = -1
        var runEnd   = -1

        func flush() {
            if runStart >= 0 {
                result.append(NSRange(location: runStart, length: runEnd - runStart))
            }
            runStart = -1; runEnd = -1
        }

        for op in ops {
            switch op {
            case .match:
                flush()
            case .onlyInA(let t):
                if runStart < 0 { runStart = t.utf16Offset }
                runEnd = t.utf16Offset + t.utf16Length
            case .onlyInB:
                break
            }
        }
        flush()
        return result
    }

    /// Character-based similarity: counts matched UTF-16 units so long tokens (e.g. identifiers)
    /// and short tokens (e.g. spaces) contribute proportionally, not equally.
    private static func similarityPercent(from ops: [DiffOp<WordToken>]) -> Int {
        var matched = 0
        var mineChars = 0
        var otherChars = 0
        for op in ops {
            switch op {
            case .match(let a, _):
                matched    += a.utf16Length
                mineChars  += a.utf16Length
                otherChars += a.utf16Length
            case .onlyInA(let a):
                mineChars  += a.utf16Length
            case .onlyInB(let b):
                otherChars += b.utf16Length
            }
        }
        let denom = max(mineChars, otherChars)
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
