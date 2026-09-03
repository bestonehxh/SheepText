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
        let resemblance = resemblancePercent(utf16Block(aLines), utf16Block(bLines))
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

    /// Size of the multiset intersection of two code-unit arrays — an O(n) upper
    /// bound on their LCS length, used when the exact DP is too big.
    ///
    /// The tally is a flat 65 536-entry table rather than a dictionary: this only
    /// runs for blocks of thousands of characters a side, where one 256 KB memset
    /// is far cheaper than that many hashes.
    private static func sharedElementCount(_ a: ArraySlice<UInt16>, _ b: ArraySlice<UInt16>) -> Int {
        var counts = [Int32](repeating: 0, count: Int(UInt16.max) + 1)
        return counts.withUnsafeMutableBufferPointer { table -> Int in
            for unit in a { table[Int(unit)] += 1 }
            var shared = 0
            for unit in b where table[Int(unit)] > 0 {
                table[Int(unit)] -= 1
                shared += 1
            }
            return shared
        }
    }

    /// The two sides of a changed block, flattened into one UTF-16 buffer with
    /// the same "\n" separators the old `joined(separator:)` used.
    ///
    /// This used to build two Strings and then `Array(String)` them, which runs
    /// the grapheme breaker over every character of the block and interns each
    /// resulting `Character` into a dictionary. The result is only ever compared
    /// against a percentage threshold, so code units answer the same question at
    /// a fraction of the cost — and they are already integers, so the interning
    /// step disappears with them.
    private static func utf16Block(_ lines: [HashedLine]) -> [UInt16] {
        var units: [UInt16] = []
        // utf16.count <= utf8.count, and utf8.count is O(1) on a native String.
        units.reserveCapacity(lines.reduce(0) { $0 + $1.normalized.utf8.count } + lines.count)
        for (index, line) in lines.enumerated() {
            if index > 0 { units.append(0x000A) }
            units.append(contentsOf: line.normalized.utf16)
        }
        return units
    }

    private static func resemblancePercent(_ a: [UInt16], _ b: [UInt16]) -> Int {
        let denom = max(a.count, b.count)
        guard denom > 0 else { return 100 }
        return Int((Double(lcsLength(a, b)) / Double(denom)) * 100.0)
    }

    /// Length of the longest common subsequence of two UTF-16 buffers.
    ///
    /// Only the length is ever consumed, so this keeps two rolling rows instead
    /// of the full n x m table. That matters a lot here: the inputs are whole
    /// changed BLOCKS joined together, so a 200-line block is ~15 000 code units
    /// a side and the old table allocated 225 million `Int`s (about 1.8 GB) on
    /// every keystroke.
    ///
    /// One exact shortcut keeps the result identical to the naive table: a
    /// common prefix and suffix always belong to some optimal LCS and can be
    /// counted directly.
    private static func lcsLength(_ a: [UInt16], _ b: [UInt16]) -> Int {
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

        var av = a[lo ..< (lo + n)]
        var bv = b[lo ..< (lo + m)]

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
