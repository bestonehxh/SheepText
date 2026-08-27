import Foundation

nonisolated enum DiffOp<T> {
    case match(T, T)
    case onlyInA(T)
    case onlyInB(T)
}

nonisolated enum DiffCalc {
    // ~32 MB ceiling for the LCS table (Int is 8 bytes on 64-bit).
    // Above this limit we fall back to a prefix/suffix heuristic that still
    // catches bulk unchanged regions without allocating a massive 2-D array.
    private static let maxLCSCells = 4_000_000

    static func diff<T>(
        _ a: [T],
        _ b: [T],
        equal: @Sendable (T, T) -> Bool
    ) -> [DiffOp<T>] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .onlyInB($0) } }
        if m == 0 { return a.map { .onlyInA($0) } }

        // The fallback decision deliberately uses the untrimmed sizes: changing
        // which algorithm runs would change the output, and this must not.
        if n * m > maxLCSCells {
            return prefixSuffixDiff(a, b, equal: equal)
        }

        // Consume a common prefix directly. This is exactly what the backtrack
        // below would do anyway — it tests `equal` before consulting the table —
        // and because the table is filled backwards, dp[i][j] depends only on
        // elements at or after i and j, so dropping a prefix cannot change a
        // single value the backtrack reads. The win is large in the common case
        // of editing near the end of an otherwise unchanged file, and total when
        // the two sides are identical.
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

        // Consume a common suffix too. A common suffix always belongs to some
        // optimal LCS, so trimming it adds a constant to every DP value in the
        // middle region and cannot change the comparisons the backtrack makes —
        // the same argument as the prefix trim above. The win is large in the
        // common case of editing near the START of an otherwise unchanged file:
        // without this the table was still sized for both full inputs.
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix
              && equal(a[n - 1 - suffix], b[m - 1 - suffix]) { suffix += 1 }

        // Dynamic-programming LCS backtracking; stable for editor-sized inputs.
        // The table is a single flat buffer of Int32 rather than an array of
        // arrays: the backtrack needs the whole table, but nesting arrays costs
        // n+1 separate heap allocations plus a double indirection on every one
        // of the n*m accesses, and Int32 halves the footprint (a 2000x2000
        // compare drops from 32 MB to 16 MB).
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

        let stride1 = rm + 1
        var dp = [Int32](repeating: 0, count: (rn + 1) * stride1)
        dp.withUnsafeMutableBufferPointer { t in
            for i in stride(from: rn - 1, through: 0, by: -1) {
                let row = i * stride1
                let next = row + stride1
                for j in stride(from: rm - 1, through: 0, by: -1) {
                    t[row + j] = equal(a[prefix + i], b[prefix + j])
                        ? t[next + j + 1] + 1
                        : max(t[next + j], t[row + j + 1])
                }
            }
        }

        var i = 0, j = 0
        while i < rn && j < rm {
            if equal(a[prefix + i], b[prefix + j]) {
                result.append(.match(a[prefix + i], b[prefix + j]))
                i += 1; j += 1
            } else if dp[(i + 1) * stride1 + j] >= dp[i * stride1 + j + 1] {
                result.append(.onlyInA(a[prefix + i])); i += 1
            } else {
                result.append(.onlyInB(b[prefix + j])); j += 1
            }
        }
        while i < rn { result.append(.onlyInA(a[prefix + i])); i += 1 }
        while j < rm { result.append(.onlyInB(b[prefix + j])); j += 1 }
        appendSuffixMatches()
        return result
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
