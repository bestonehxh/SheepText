import Foundation

nonisolated enum DiffOp<T> {
    case match(T, T)
    case onlyInA(T)
    case onlyInB(T)
}

nonisolated enum DiffCalc {

    /// Bounds on the Myers search. Myers is O(D x (n+m)) in time and — with the
    /// packed V trace below — O(D^2 / 2) `Int32` in space, so both have to be
    /// bounded for inputs that are not related at all (there D approaches n+m).
    /// Each bound is on the thing it is actually about:
    ///
    /// * `myersWorkBudget` bounds the TIME, counted AS IT GOES (see `work` in
    ///   `myersMiddle`): one unit per diagonal visited plus one per element
    ///   comparison inside a snake. It used to be spent up front as
    ///   `myersWorkBudget / (rn + rm)`, which made the tolerated edit distance
    ///   inversely proportional to file size — roughly `D <= 6_000_000 / n`, so
    ///   `maxD` was 60 on a 200 000-line pair and forty scattered edits fell
    ///   back and reported 190 243 changed rows. That is the same failure the
    ///   old `n*m > 4_000_000` cliff produced, moved up a couple of orders of
    ///   magnitude.
    /// * `myersMinDistance` is the distance ALWAYS allowed, whatever the inputs
    ///   look like — the 3000 every earlier release documented, kept so that
    ///   nothing that used to be exact stops being exact.
    /// * `myersMaxDistance` bounds the MEMORY: the trace is D*(D+1)/2 `Int32`,
    ///   so 4096 is 8.4 M entries = 34 MB, transient and allocated on the
    ///   background compare queue. (It was 3000 = 18 MB, which is below the
    ///   D = 4000 that two thousand edited lines cost — in a file that is still
    ///   99 % identical to its twin.)
    /// * Between the two, the ceiling is RELATEDNESS, which is what "these two
    ///   files are not versions of each other" actually means: `D >= 3/4 (rn+rm)`
    ///   leaves fewer than a quarter of the lines shared. On the 2000-line pairs
    ///   the numbers below were measured on it lands on exactly the 3000 the old
    ///   memory ceiling did, so every documented boundary is unchanged.
    ///
    /// What the ceilings mean in practice. D is about twice the number of lines
    /// that actually differ, so:
    ///
    /// * a pair differing in up to ~2000 lines is diffed EXACTLY whatever its
    ///   size — 200 000 lines with 40 scattered edits, or with 2000 of them;
    /// * above that the exact search is abandoned, and so it is when the sides
    ///   are mostly unrelated whatever their size. Measured on 2000-line pairs:
    ///   50 % changed -> D = 2000, 75 % changed -> D = 3000, both exact; fully
    ///   disjoint -> D = 4000, which falls back.
    ///
    /// The fallback is the existing `prefixSuffixDiff`, i.e. exactly the output
    /// the old code produced in its own fallback regime — so nothing that used
    /// to fall back changes shape.
    private static let myersWorkBudget = 24_000_000
    private static let myersMinDistance = 3_000
    private static let myersMaxDistance = 4_096

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

        // Relatedness, floored by the distance always allowed and capped by the
        // trace's memory ceiling. The time bound is counted inside `myersMiddle`
        // rather than guessed at from the input size.
        let relatednessCeiling = 3 * (rn + rm) / 4
        let maxD = min(myersMaxDistance, max(myersMinDistance, relatednessCeiling))
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
    /// Returns nil when the edit distance exceeds `maxD`, or when the search has
    /// spent `myersWorkBudget` units of work, so the caller can fall back rather
    /// than spend O(n*m) proving what it already suspects.
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

        // Work actually done, not work predicted: one unit per diagonal visited
        // and one per element comparison inside a snake. A pair drawn from a
        // tiny alphabet (a config that is mostly "!" and blank lines) has a long
        // snake on every diagonal, which no function of `n` and `m` can see
        // coming — this is the only bound that catches it.
        var work = 0
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
            work += d + 1
            if work > myersWorkBudget { return nil }

            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[vOffset + k - 1] < v[vOffset + k + 1]) {
                    x = Int(v[vOffset + k + 1])          // down: b contributes a line
                } else {
                    x = Int(v[vOffset + k - 1]) + 1      // right: a contributes a line
                }
                var y = x - k
                let snakeStart = x
                while x < n && y < m && equal(a[aOffset + x], b[bOffset + y]) {
                    x += 1
                    y += 1
                }
                work += x - snakeStart
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
