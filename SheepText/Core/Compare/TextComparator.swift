import Foundation

nonisolated struct ChangedLine: Equatable, Sendable {
    let lineNumber: Int
    let text: String
}

nonisolated enum CompareBlock: Equatable, Sendable {
    case match(ClosedRange<Int>, ClosedRange<Int>)
    case onlyInA(ClosedRange<Int>)
    case onlyInB(ClosedRange<Int>)
    case changed([ChangedLine], [ChangedLine])
}

nonisolated struct CompareSummary: Equatable, Sendable {
    let added: Int
    let removed: Int
    let changed: Int
    let blocks: [CompareBlock]
}

nonisolated enum CompareResult: Equatable, Sendable {
    case match
    case cancelled
    case mismatch(CompareSummary)
}

nonisolated enum TextComparator {
    static func compare(_ textA: String, _ textB: String, options: CompareOptions) -> CompareResult {
        compare(rawLinesA: LineHashing.splitLines(textA),
                rawLinesB: LineHashing.splitLines(textB),
                options: options)
    }

    /// Same comparison, but for callers that have already split the text into
    /// lines. They must use `LineHashing.splitLines`, or the line numbers in the
    /// result will index a differently-shaped array.
    static func compare(rawLinesA: [String], rawLinesB: [String], options: CompareOptions) -> CompareResult {
        let linesA = LineHashing.hashLines(rawLinesA, options: options)
        let linesB = LineHashing.hashLines(rawLinesB, options: options)

        let ops = DiffCalc.diff(linesA, linesB) { l, r in
            l.hash == r.hash && l.normalized == r.normalized
        }

        var blocks: [CompareBlock] = []
        var idx = 0
        var added = 0
        var removed = 0
        var changed = 0

        while idx < ops.count {
            switch ops[idx] {
            case .match(let a, let b):
                let startA = a.lineNumber
                let startB = b.lineNumber
                var endA = startA
                var endB = startB
                idx += 1
                while idx < ops.count {
                    if case .match(let na, let nb) = ops[idx], na.lineNumber == endA + 1, nb.lineNumber == endB + 1 {
                        endA = na.lineNumber
                        endB = nb.lineNumber
                        idx += 1
                    } else {
                        break
                    }
                }
                blocks.append(.match(startA...endA, startB...endB))

            case .onlyInA:
                let start = idx
                var end = idx
                while end + 1 < ops.count, case .onlyInA = ops[end + 1] { end += 1 }

                if end + 1 < ops.count, case .onlyInB = ops[end + 1] {
                    // Changed chunk candidate: onlyInA run followed by onlyInB run.
                    var bEnd = end + 1
                    while bEnd + 1 < ops.count, case .onlyInB = ops[bEnd + 1] { bEnd += 1 }
                    let aLines = ops[start...end].compactMap { op -> HashedLine? in if case .onlyInA(let l) = op { return l }; return nil }
                    let bLines = ops[(end + 1)...bEnd].compactMap { op -> HashedLine? in if case .onlyInB(let l) = op { return l }; return nil }
                    changed += appendChangedOrSplit(aLines: aLines, bLines: bLines, options: options, removed: &removed, added: &added, blocks: &blocks)
                    idx = bEnd + 1
                } else {
                    let aLines = ops[start...end].compactMap { op -> HashedLine? in if case .onlyInA(let l) = op { return l }; return nil }
                    if let first = aLines.first?.lineNumber, let last = aLines.last?.lineNumber {
                        removed += aLines.count
                        blocks.append(.onlyInA(first...last))
                    }
                    idx = end + 1
                }

            case .onlyInB:
                let start = idx
                var end = idx
                while end + 1 < ops.count, case .onlyInB = ops[end + 1] { end += 1 }

                if end + 1 < ops.count, case .onlyInA = ops[end + 1] {
                    // Changed chunk candidate: onlyInB run followed by onlyInA run.
                    var aEnd = end + 1
                    while aEnd + 1 < ops.count, case .onlyInA = ops[aEnd + 1] { aEnd += 1 }
                    let bLines = ops[start...end].compactMap { op -> HashedLine? in if case .onlyInB(let l) = op { return l }; return nil }
                    let aLines = ops[(end + 1)...aEnd].compactMap { op -> HashedLine? in if case .onlyInA(let l) = op { return l }; return nil }
                    changed += appendChangedOrSplit(aLines: aLines, bLines: bLines, options: options, removed: &removed, added: &added, blocks: &blocks)
                    idx = aEnd + 1
                } else {
                    let bLines = ops[start...end].compactMap { op -> HashedLine? in if case .onlyInB(let l) = op { return l }; return nil }
                    if let first = bLines.first?.lineNumber, let last = bLines.last?.lineNumber {
                        added += bLines.count
                        blocks.append(.onlyInB(first...last))
                    }
                    idx = end + 1
                }
            }
        }

        if added == 0 && removed == 0 && changed == 0 {
            return .match
        }

        return .mismatch(CompareSummary(added: added, removed: removed, changed: changed, blocks: blocks))
    }

    /// Emit a `.changed` block when resemblance is high enough, otherwise emit separate add/remove blocks.
    /// Returns the number of changed-line units added to the changed counter.
    @discardableResult
    private static func appendChangedOrSplit(
        aLines: [HashedLine],
        bLines: [HashedLine],
        options: CompareOptions,
        removed: inout Int,
        added: inout Int,
        blocks: inout [CompareBlock]
    ) -> Int {
        let resemblance = resemblancePercent(
            aLines.map(\.normalized).joined(separator: "\n"),
            bLines.map(\.normalized).joined(separator: "\n")
        )
        if resemblance >= options.changedResemblPercent {
            let pairCount = max(aLines.count, bLines.count)
            var changedA: [ChangedLine] = []
            var changedB: [ChangedLine] = []
            for i in 0..<pairCount {
                if let la = i < aLines.count ? aLines[i] : nil {
                    changedA.append(ChangedLine(lineNumber: la.lineNumber, text: la.raw))
                }
                if let lb = i < bLines.count ? bLines[i] : nil {
                    changedB.append(ChangedLine(lineNumber: lb.lineNumber, text: lb.raw))
                }
            }
            blocks.append(.changed(changedA, changedB))
            return max(changedA.count, changedB.count)
        } else {
            if let first = aLines.first?.lineNumber, let last = aLines.last?.lineNumber {
                removed += aLines.count
                blocks.append(.onlyInA(first...last))
            }
            if let first = bLines.first?.lineNumber, let last = bLines.last?.lineNumber {
                added += bLines.count
                blocks.append(.onlyInB(first...last))
            }
            return 0
        }
    }

    /// Ceiling on the LCS table for `resemblancePercent`, in cells. One million
    /// inner iterations is a millisecond or two; the old unbounded version could
    /// reach hundreds of millions on a large changed block.
    private static let resemblanceCellLimit = 1_000_000

    /// Size of the multiset intersection of two interned character arrays — an
    /// O(n) upper bound on their LCS length, used when the exact DP is too big.
    private static func sharedElementCount(_ a: [Int32], _ b: [Int32]) -> Int {
        var counts: [Int32: Int] = [:]
        counts.reserveCapacity(a.count)
        for id in a { counts[id, default: 0] += 1 }
        var shared = 0
        for id in b {
            guard let remaining = counts[id], remaining > 0 else { continue }
            counts[id] = remaining - 1
            shared += 1
        }
        return shared
    }

    private static func resemblancePercent(_ a: String, _ b: String) -> Int {
        if a.isEmpty && b.isEmpty { return 100 }
        let aa = Array(a)
        let bb = Array(b)
        let denom = max(aa.count, bb.count)
        guard denom > 0 else { return 100 }
        return Int((Double(lcsLength(aa, bb)) / Double(denom)) * 100.0)
    }

    /// Length of the longest common subsequence of two character arrays.
    ///
    /// Only the length is ever consumed, so this keeps two rolling rows instead
    /// of the full n x m table. That matters a lot here: the inputs are whole
    /// changed BLOCKS joined together, so a 200-line block is ~15 000 characters
    /// a side and the old table allocated 225 million `Int`s (about 1.8 GB) on
    /// every keystroke.
    ///
    /// Two exact shortcuts keep the result byte-identical to the naive table: a
    /// common prefix and suffix always belong to some optimal LCS and can be
    /// counted directly, and characters are interned to `Int32` ids first
    /// because comparing grapheme clusters is far more expensive than comparing
    /// integers.
    private static func lcsLength(_ a: [Character], _ b: [Character]) -> Int {
        var n = a.count
        var m = b.count
        if n == 0 || m == 0 { return 0 }

        // Common prefix / suffix contribute to the LCS in full.
        var lo = 0
        while lo < n && lo < m && a[lo] == b[lo] { lo += 1 }
        if lo == n || lo == m { return lo }

        var hi = 0
        while hi < n - lo && hi < m - lo && a[n - 1 - hi] == b[m - 1 - hi] { hi += 1 }

        let fixed = lo + hi
        n -= fixed
        m -= fixed
        if n == 0 || m == 0 { return fixed }

        // Intern to integer ids: grapheme-cluster equality is expensive, and the
        // inner loop runs n x m times.
        var ids: [Character: Int32] = [:]
        ids.reserveCapacity(n + m)
        var next: Int32 = 0
        var av = [Int32](repeating: 0, count: n)
        var bv = [Int32](repeating: 0, count: m)
        for i in 0..<n {
            let c = a[lo + i]
            if let id = ids[c] { av[i] = id } else { ids[c] = next; av[i] = next; next += 1 }
        }
        for j in 0..<m {
            let c = b[lo + j]
            if let id = ids[c] { bv[j] = id } else { ids[c] = next; bv[j] = next; next += 1 }
        }

        // Iterate rows over the longer side so the rolling rows stay small.
        if m > n {
            swap(&av, &bv)
            swap(&n, &m)
        }

        // Rolling rows fixed the MEMORY of this DP, but not its time: it is still
        // n*m, and the inputs are whole changed BLOCKS joined together. A block of
        // 200 edited lines is roughly 15 000 characters a side — 225 million inner
        // iterations, on every keystroke, before a single character is drawn.
        //
        // The prefix/suffix trim above already collapses the common case of a big
        // but mostly-identical block, so this limit is only reached by blocks that
        // are both large AND genuinely different. There, fall back to an O(n)
        // multiset intersection: how many characters the two sides share ignoring
        // order. That is an upper bound on the true LCS length, so the caller can
        // only ever decide "similar enough to pair up" more readily than before —
        // never less. A huge block therefore stays one `.changed` block instead of
        // being split into separate add/remove blocks, and the word-level diff
        // inside it declines on its own much smaller size limits.
        if n * m > resemblanceCellLimit {
            return fixed + sharedElementCount(av, bv)
        }

        var prev = [Int32](repeating: 0, count: m + 1)
        var cur  = [Int32](repeating: 0, count: m + 1)
        av.withUnsafeBufferPointer { ap in
            bv.withUnsafeBufferPointer { bp in
                for i in 0..<n {
                    let ai = ap[i]
                    prev.withUnsafeBufferPointer { pp in
                        cur.withUnsafeMutableBufferPointer { cp in
                            cp[0] = 0
                            for j in 0..<m {
                                cp[j + 1] = ai == bp[j] ? pp[j] + 1 : max(pp[j + 1], cp[j])
                            }
                        }
                    }
                    swap(&prev, &cur)
                }
            }
        }
        return fixed + Int(prev[m])
    }
}
