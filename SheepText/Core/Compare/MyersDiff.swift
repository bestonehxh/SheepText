import Foundation

nonisolated enum DiffOp<T> {
    case match(T, T)
    case onlyInA(T)
    case onlyInB(T)
}

nonisolated enum DiffCalc {

    /// Ceiling on the edit distance the Myers search explores before giving up.
    ///
    /// Myers is O(D x (n+m)) in time and — with the packed V trace below —
    /// O(D^2 / 2) `Int32` in space, so both have to be bounded for inputs that
    /// are not related at all (there D approaches n+m).
    ///
    /// * `myersWorkBudget / (rn + rm)` bounds the TIME: roughly 24 million
    ///   element comparisons before we give up.
    /// * `myersMaxDistance` bounds the MEMORY: D <= 3000 means a trace of
    ///   3000*3001/2 `Int32` = 18 MB, the same order as the 16 MB the old exact
    ///   LCS table allocated for two 2000-line files (and that table grew
    ///   quadratically from there, which is why the old code refused above it).
    ///
    /// What the ceiling means in practice. D is about twice the number of lines
    /// that actually differ, so:
    ///
    /// * anything whose trimmed middles total 3000 lines or fewer is diffed
    ///   EXACTLY whatever it contains — including the two 2001-line files
    ///   differing in two lines that the old size-based cliff reported as 1991
    ///   changed lines;
    /// * above that, the ceiling is only reached when the sides are mostly
    ///   unrelated. Measured on 2000-line pairs: 50 % changed -> D = 2000,
    ///   75 % changed -> D = 3000, both exact; fully disjoint -> D = 4000,
    ///   which falls back.
    ///
    /// The fallback is the existing `prefixSuffixDiff`, i.e. exactly the output
    /// the old code produced in its own fallback regime — so nothing that used
    /// to fall back changes shape, it just falls back on relatedness instead of
    /// on size. The cost is that a hopeless pair now spends ~24 ms proving it
    /// (two disjoint 2000-line files) where the old exact DP took ~4 ms to
    /// return the same zero matches.
    private static let myersWorkBudget = 24_000_000
    private static let myersMaxDistance = 3_000

    static func diff<T>(
        _ a: [T],
        _ b: [T],
        equal: @Sendable (T, T) -> Bool
    ) -> [DiffOp<T>] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .onlyInB($0) } }
        if m == 0 { return a.map { .onlyInA($0) } }

        // Consume a common prefix directly. A common prefix always belongs to
        // some optimal edit script, so removing it cannot change the answer,
        // and the win is large in the common case of editing near the end of an
        // otherwise unchanged file (total when the two sides are identical).
        var prefix = 0
        while prefix < n && prefix < m && equal(a[prefix], b[prefix]) { prefix += 1 }

        var result: [DiffOp<T>] = []
        result.reserveCapacity(max(n, m))
        for k in 0..<prefix { result.append(.match(a[k], b[k])) }

        if prefix == n || prefix == m {
            for k in prefix..<n { result.append(.onlyInA(a[k])) }
            for k in prefix..<m { result.append(.onlyInB(b[k])) }
            return result
        }

        // Consume a common suffix too, for the same reason — the win here is
        // the mirror case of editing near the START of an unchanged file.
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix
              && equal(a[n - 1 - suffix], b[m - 1 - suffix]) { suffix += 1 }

        // Indices below are relative to the trimmed middle of each input.
        let rn = n - prefix - suffix
        let rm = m - prefix - suffix

        func appendSuffixMatches() {
            for k in 0..<suffix { result.append(.match(a[n - suffix + k], b[m - suffix + k])) }
        }

        if rn == 0 || rm == 0 {
            for k in 0..<rn { result.append(.onlyInA(a[prefix + k])) }
            for k in 0..<rm { result.append(.onlyInB(b[prefix + k])) }
            appendSuffixMatches()
            return result
        }

        let maxD = min(myersMaxDistance, myersWorkBudget / (rn + rm))
        if let middle = myersMiddle(a, b, aOffset: prefix, bOffset: prefix,
                                    n: rn, m: rm, maxD: maxD, equal: equal) {
            result.append(contentsOf: middle)
            appendSuffixMatches()
            return result
        }

        // Edit distance above the ceiling: the two sides are not meaningfully
        // related. Same output the old size-based cliff produced (this recomputes
        // the trim, which is O(n) and only happens on this cold path).
        return prefixSuffixDiff(a, b, equal: equal)
    }

    /// Greedy forward Myers (O(ND)) over `a[aOffset ..< aOffset+n]` and
    /// `b[bOffset ..< bOffset+m]`, with a saved V trace for the backtrack.
    ///
    /// Returns nil when the edit distance exceeds `maxD`, so the caller can fall
    /// back rather than spend O(n*m) proving what it already suspects.
    ///
    /// The trace is packed: row `d` stores only the diagonals reachable at
    /// distance `d-1`, i.e. k in `-(d-1) ... (d-1)` stepping by 2 — `d` entries
    /// at offset `d*(d-1)/2`. Storing a full copy of V per round (the textbook
    /// formulation) would be O(D*(n+m)), which is 6 MB *per round* on a
    /// 200 000-line file.
    private static func myersMiddle<T>(
        _ a: [T],
        _ b: [T],
        aOffset: Int,
        bOffset: Int,
        n: Int,
        m: Int,
        maxD: Int,
        equal: (T, T) -> Bool
    ) -> [DiffOp<T>]? {
        let bound = min(max(maxD, 0), n + m)
        var v = [Int32](repeating: 0, count: 2 * bound + 3)
        let vOffset = bound + 1
        var trace: [Int32] = []
        trace.reserveCapacity(256)

        var found = -1
        var d = 0
        search: while d <= bound {
            // Snapshot the diagonals the backtrack will read for this round.
            if d > 0 {
                var k = -(d - 1)
                while k <= d - 1 {
                    trace.append(v[vOffset + k])
                    k += 2
                }
            }

            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[vOffset + k - 1] < v[vOffset + k + 1]) {
                    x = Int(v[vOffset + k + 1])          // down: b contributes a line
                } else {
                    x = Int(v[vOffset + k - 1]) + 1      // right: a contributes a line
                }
                var y = x - k
                while x < n && y < m && equal(a[aOffset + x], b[bOffset + y]) {
                    x += 1
                    y += 1
                }
                v[vOffset + k] = Int32(x)
                if x >= n && y >= m {
                    found = d
                    break search
                }
                k += 2
            }
            d += 1
        }
        guard found >= 0 else { return nil }

        var reversed: [DiffOp<T>] = []
        reversed.reserveCapacity(n + m)
        var x = n
        var y = m
        var step = found
        while step > 0 {
            let row = step * (step - 1) / 2
            let k = x - y
            let prevK: Int
            if k == -step
                || (k != step
                    && trace[row + (k - 1 + step - 1) / 2] < trace[row + (k + 1 + step - 1) / 2]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = Int(trace[row + (prevK + step - 1) / 2])
            let prevY = prevX - prevK
            while x > prevX && y > prevY {
                reversed.append(.match(a[aOffset + x - 1], b[bOffset + y - 1]))
                x -= 1
                y -= 1
            }
            if x > prevX {
                reversed.append(.onlyInA(a[aOffset + x - 1]))
                x -= 1
            } else {
                reversed.append(.onlyInB(b[bOffset + y - 1]))
                y -= 1
            }
            step -= 1
        }
        while x > 0 && y > 0 {
            reversed.append(.match(a[aOffset + x - 1], b[bOffset + y - 1]))
            x -= 1
            y -= 1
        }
        return reversed.reversed()
    }

    /// Fast O(n) fallback: matches common prefix/suffix exactly, marks the
    /// middle as interleaved adds/removes so TextComparator can still pair them.
    private static func prefixSuffixDiff<T>(
        _ a: [T],
        _ b: [T],
        equal: @Sendable (T, T) -> Bool
    ) -> [DiffOp<T>] {
        let n = a.count, m = b.count
        var prefix = 0
        while prefix < n && prefix < m && equal(a[prefix], b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix
              && equal(a[n - 1 - suffix], b[m - 1 - suffix]) { suffix += 1 }

        var result: [DiffOp<T>] = []
        for i in 0..<prefix { result.append(.match(a[i], b[i])) }
        // Interleave A removals and B insertions so the changed-pair detector fires.
        let aMiddle = (prefix ..< n - suffix).map { a[$0] }
        let bMiddle = (prefix ..< m - suffix).map { b[$0] }
        let midCount = max(aMiddle.count, bMiddle.count)
        for k in 0..<midCount {
            if k < aMiddle.count { result.append(.onlyInA(aMiddle[k])) }
            if k < bMiddle.count { result.append(.onlyInB(bMiddle[k])) }
        }
        for i in 0..<suffix { result.append(.match(a[n - suffix + i], b[m - suffix + i])) }
        return result
    }
}
