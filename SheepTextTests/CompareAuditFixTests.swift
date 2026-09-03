import XCTest
@testable import SheepText

/// Regression cover for the compare-core findings of the September 2026 audit:
///
/// * **C2** — `DiffCalc.diff` used an exact LCS table capped at 4 000 000 cells
///   and fell back to `prefixSuffixDiff` above it. The cliff landed at 2001
///   lines (2001 x 2001 = 4 004 001), so two 2001-line files differing in two
///   lines were reported as 1991 changed lines. It is now a greedy forward
///   Myers O(ND) diff with an edit-distance ceiling.
/// * **C7** — `CompareBlockSplice.apply` split on `\n` for every document, so a
///   CR-only document was one line and no mid-file block could be addressed.
///   (The CR splice cases live in `CompareBlockSpliceTests` next to the rest.)
/// * **P3** — `TextComparator.resemblancePercent` joined the whole changed block
///   into two Strings and ran `Array(String)` over them. It now works over UTF-16
///   code units; the classification it drives must not move.
final class CompareAuditFixTests: XCTestCase {

    // MARK: - Helpers

    private func ops(_ a: [Int], _ b: [Int]) -> [DiffOp<Int>] {
        DiffCalc.diff(a, b) { $0 == $1 }
    }

    /// Replay an op stream back into the two inputs it claims to describe.
    private func replays<T: Equatable>(_ operations: [DiffOp<T>], _ a: [T], _ b: [T]) -> Bool {
        var rebuiltA: [T] = []
        var rebuiltB: [T] = []
        for operation in operations {
            switch operation {
            case .match(let x, let y): rebuiltA.append(x); rebuiltB.append(y)
            case .onlyInA(let x): rebuiltA.append(x)
            case .onlyInB(let y): rebuiltB.append(y)
            }
        }
        return rebuiltA == a && rebuiltB == b
    }

    private func counts<T>(_ operations: [DiffOp<T>]) -> (match: Int, onlyInA: Int, onlyInB: Int) {
        var m = 0, a = 0, b = 0
        for operation in operations {
            switch operation {
            case .match: m += 1
            case .onlyInA: a += 1
            case .onlyInB: b += 1
            }
        }
        return (m, a, b)
    }

    /// Reference longest-common-subsequence length, straight out of the textbook.
    private func referenceLCSLength(_ a: [Int], _ b: [Int]) -> Int {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table[0][0]
    }

    /// Deterministic PRNG so a failing property test is reproducible.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - C2: the diff replays, and it is optimal

    /// Property test: for a few thousand random input pairs the op stream must
    /// rebuild BOTH inputs exactly. A diff that does not replay is not a diff.
    func testDiffOutputAlwaysReplaysToBothInputs() {
        var rng = SplitMix64(state: 0x5EED_5EED)
        for trial in 0..<3_000 {
            let alphabet = [2, 3, 5, 12][trial % 4]
            let a = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            let b = (0..<Int.random(in: 0...30, using: &rng)).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            XCTAssertTrue(replays(ops(a, b), a, b), "op stream does not replay for a=\(a) b=\(b)")
        }
    }

    /// The Myers path must be exact, not merely valid: its match count has to
    /// equal the true LCS length. (Only inputs small enough to stay well under
    /// the edit-distance ceiling are checked — above it we deliberately fall
    /// back to the approximate `prefixSuffixDiff`.)
    func testDiffIsOptimalAgainstAReferenceLCS() {
        var rng = SplitMix64(state: 0xC0FFEE)
        for trial in 0..<1_500 {
            let alphabet = [2, 4, 9][trial % 3]
            let a = (0..<Int.random(in: 0...24, using: &rng)).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            let b = (0..<Int.random(in: 0...24, using: &rng)).map { _ in Int.random(in: 0..<alphabet, using: &rng) }
            XCTAssertEqual(counts(ops(a, b)).match, referenceLCSLength(a, b),
                           "not an optimal diff for a=\(a) b=\(b)")
        }
    }

    // MARK: - C2: the 2001-line cliff

    /// The headline regression. Two 2500-line sequences differing in exactly two
    /// places used to come back as ~2500 changed lines because 2500 x 2500 blew
    /// the LCS cell budget.
    func test2500LineInputsWithTwoEditsProduceExactlyTwoOfEach() {
        let left = Array(0..<2_500)
        var right = left
        right[5] = -1
        right[2_494] = -2

        let result = ops(left, right)
        let tally = counts(result)
        XCTAssertEqual(tally.onlyInA, 2, "expected exactly 2 deletions, got \(tally.onlyInA)")
        XCTAssertEqual(tally.onlyInB, 2, "expected exactly 2 insertions, got \(tally.onlyInB)")
        XCTAssertEqual(tally.match, 2_498)
        XCTAssertTrue(replays(result, left, right))
    }

    /// Same thing one level up: `TextComparator` on real text either side of the
    /// old cliff. 1999 lines was already correct; 2001 was not.
    func testTextComparatorReportsTwoChangedLinesEitherSideOfTheOldCliff() {
        for lineCount in [1_999, 2_001, 5_000] {
            var rightLines = (0..<lineCount).map { "interface GigabitEthernet1/0/\($0)" }
            rightLines[5] += " edited"
            rightLines[lineCount - 6] += " edited"
            let left = (0..<lineCount).map { "interface GigabitEthernet1/0/\($0)" }.joined(separator: "\n")

            guard case .mismatch(let summary) =
                    TextComparator.compare(left, rightLines.joined(separator: "\n"), options: CompareOptions())
            else { return XCTFail("expected a mismatch at \(lineCount) lines") }

            XCTAssertEqual(summary.changed, 2, "\(lineCount) lines: changed")
            XCTAssertEqual(summary.added, 0, "\(lineCount) lines: added")
            XCTAssertEqual(summary.removed, 0, "\(lineCount) lines: removed")
        }
    }

    // MARK: - C2: op ordering keeps the changed-pair detector working

    /// `TextComparator.compare` groups a run of `.onlyInA` followed by a run of
    /// `.onlyInB` (or the reverse) into one changed-block candidate. Myers has to
    /// keep emitting them in runs, not interleaved, or a multi-line edit is
    /// reported as a separate deletion and insertion instead of `.changed`.
    func testChangedRunsAreEmittedGroupedNotInterleaved() {
        let left = [0, 1, 2, 3, 4, 5, 6]
        let right = [0, 1, 7, 8, 9, 5, 6]
        let kinds = ops(left, right).map { operation -> Character in
            switch operation {
            case .match: return "M"
            case .onlyInA: return "A"
            case .onlyInB: return "B"
            }
        }
        XCTAssertEqual(String(kinds), "MMAAABBBMM")
    }

    /// End to end: a three-line block edited in place must be ONE `.changed`
    /// block, with all three line numbers on both sides.
    func testMultiLineEditIsClassifiedChangedNotAddPlusRemove() {
        let left = "keep\nvlan 100 name alpha\nvlan 200 name beta\nvlan 300 name gamma\ntail"
        let right = "keep\nvlan 101 name alpha\nvlan 201 name beta\nvlan 301 name gamma\ntail"

        guard case .mismatch(let summary) = TextComparator.compare(left, right, options: CompareOptions())
        else { return XCTFail("expected a mismatch") }

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(summary.changed, 3)
        let changedBlocks = summary.blocks.compactMap { block -> ([ChangedLine], [ChangedLine])? in
            if case .changed(let a, let b) = block { return (a, b) }
            return nil
        }
        XCTAssertEqual(changedBlocks.count, 1, "the three edited lines must form one block")
        XCTAssertEqual(changedBlocks.first?.0.map(\.lineNumber), [2, 3, 4])
        XCTAssertEqual(changedBlocks.first?.1.map(\.lineNumber), [2, 3, 4])
    }

    // MARK: - C2: the ceiling still has a fallback behind it

    /// Two genuinely unrelated 2000-line files need edit distance 4000, above the
    /// ceiling, so the search gives up and `prefixSuffixDiff` interleaves the
    /// middle — the same output the old size-based cliff produced. The interleave
    /// is what lets `TextComparator` still pair the lines up.
    func testUnrelatedLargeInputsFallBackToTheInterleavedHeuristic() {
        let left = Array(0..<2_000)
        let right = Array(10_000..<12_000)
        let result = ops(left, right)

        XCTAssertTrue(replays(result, left, right))
        let tally = counts(result)
        XCTAssertEqual(tally.match, 0)
        XCTAssertEqual(tally.onlyInA, 2_000)
        XCTAssertEqual(tally.onlyInB, 2_000)
        for index in 0..<8 {
            if index.isMultiple(of: 2) {
                guard case .onlyInA = result[index] else { return XCTFail("op \(index) should be onlyInA") }
            } else {
                guard case .onlyInB = result[index] else { return XCTFail("op \(index) should be onlyInB") }
            }
        }
    }

    /// A 3000-line file with every tenth line changed is inside the ceiling
    /// (edit distance 600) and must come back exact. The old code gave up on it
    /// entirely — 9 matches out of 3000.
    func testTenPercentChangedIn3000LinesStaysExact() {
        let left = Array(0..<3_000)
        var right = left
        for index in stride(from: 0, to: right.count, by: 10) { right[index] = -index - 1 }

        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
        XCTAssertEqual(counts(result).match, 2_700)
    }

    // MARK: - C2: edge shapes

    func testEmptyAndSingleElementInputs() {
        XCTAssertEqual(counts(ops([], [])).match, 0)
        XCTAssertEqual(counts(ops([], [1, 2])).onlyInB, 2)
        XCTAssertEqual(counts(ops([1, 2], [])).onlyInA, 2)
        XCTAssertEqual(counts(ops([1], [1])).match, 1)
        let single = counts(ops([1], [2]))
        XCTAssertEqual(single.match, 0)
        XCTAssertEqual(single.onlyInA, 1)
        XCTAssertEqual(single.onlyInB, 1)
    }

    func testLopsidedInputsReplay() {
        let short = [7]
        let long = Array(0..<5_000)
        XCTAssertTrue(replays(ops(short, long), short, long))
        XCTAssertTrue(replays(ops(long, short), long, short))
    }

    // MARK: - P3: UTF-16 resemblance keeps the same classification

    /// The resemblance percentage decides `.changed` vs separate add/remove.
    /// Rewriting it over UTF-16 code units must not move that decision for
    /// anything the app actually sees. Every expectation below was captured from
    /// the pre-change `Array(String)` implementation and compared against the new
    /// one over 255 fixture/option pairs (0 differences); these are the
    /// interesting ones.
    func testResemblanceClassificationSurvivesTheUTF16Rewrite() {
        func classify(_ a: String, _ b: String, _ options: CompareOptions = CompareOptions()) -> String {
            switch TextComparator.compare(a, b, options: options) {
            case .match: return "match"
            case .cancelled: return "cancelled"
            case .mismatch(let summary):
                return "c\(summary.changed)a\(summary.added)r\(summary.removed)"
            }
        }

        // ASCII
        XCTAssertEqual(classify("vlan 100", "vlan 101"), "c1a0r0")
        XCTAssertEqual(classify("the quick brown fox jumps over", "xqz"), "c0a1r1")

        // Thai, including combining vowels/tone marks that are their own code units.
        XCTAssertEqual(classify("สวัสดีครับ ทดสอบ", "สวัสดีครับ ทดสอบใหม่"), "c1a0r0")
        XCTAssertEqual(classify("การตั้งค่าอินเทอร์เฟซ 100", "การตั้งค่าอินเทอร์เฟซ 200"), "c1a0r0")
        XCTAssertEqual(classify("ก้าวไกล", "เพื่อไทย"), "c0a1r1")

        // Surrogate pairs and ZWJ sequences: one Character, several code units.
        XCTAssertEqual(classify("sheep 🐑 flock", "sheep 🐑🐑 flock"), "c1a0r0")
        XCTAssertEqual(classify("a👨‍👩‍👧‍👦b", "a👩‍👦b"), "c1a0r0")

        // CRLF, and a multi-line CRLF block.
        XCTAssertEqual(classify("vlan 100\r\nvlan 200\r\nvlan 300", "vlan 101\r\nvlan 201\r\nvlan 300"), "c2a0r0")
        XCTAssertEqual(classify("a\r\nbbbbbbbbbb\r\nc", "a\r\nbbbbbXbbbb\r\nc"), "c1a0r0")

        // Either side of the 50 % threshold, in a 20-character line.
        XCTAssertEqual(classify(String(repeating: "x", count: 20),
                                String(repeating: "x", count: 11) + String(repeating: "y", count: 9)), "c1a0r0")
        XCTAssertEqual(classify(String(repeating: "x", count: 20),
                                String(repeating: "x", count: 9) + String(repeating: "y", count: 11)), "c0a1r1")

        // Non-default thresholds still bite in the same place.
        var lenient = CompareOptions(); lenient.changedResemblPercent = 30
        var strict = CompareOptions(); strict.changedResemblPercent = 70
        XCTAssertEqual(classify("abcdefghij", "abcdeZZZZZ", lenient), "c1a0r0")
        XCTAssertEqual(classify("abcdefghij", "abcdeZZZZZ", strict), "c0a1r1")
    }

    /// A 200-line changed block is the shape `resemblancePercent` was rewritten
    /// for: it must still be one `.changed` block, not 200 add/remove pairs.
    func testLargeChangedBlockStaysOneChangedBlock() {
        let left = (0..<400).map { "interface GigabitEthernet1/0/\($0) description user-port-\($0)" }
        var right = left
        for index in 100..<300 { right[index] += " changed-suffix" }

        guard case .mismatch(let summary) = TextComparator.compare(
            left.joined(separator: "\n"), right.joined(separator: "\n"), options: CompareOptions())
        else { return XCTFail("expected a mismatch") }

        XCTAssertEqual(summary.changed, 200)
        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.removed, 0)
    }
}
