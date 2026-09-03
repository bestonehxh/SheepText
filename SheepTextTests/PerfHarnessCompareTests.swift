//
//  PerfHarnessCompareTests.swift
//  Before/after workloads for the compare core (audit findings C2 and P3).
//  Each test prints one `PERF {...}` JSON line per workload; grep them out of
//  the xcodebuild log and diff the medians.
//
//  NOTE ON CHECKSUMS. The harness treats a changed checksum as a behaviour
//  change rather than an optimisation, and for the three `diff_*` workloads
//  below it IS one, deliberately: before the Myers rewrite `DiffCalc.diff` gave
//  up on anything over 2000 lines and returned ~2n interleaved add/remove ops
//  instead of a real diff, so its op checksum was much larger. Expect these
//  three to move between the pre-fix and post-fix runs, and expect them to be
//  stable from then on. `compare_*` checksums must not move at all.
//

import XCTest
@testable import SheepText

final class PerfHarnessCompareTests: XCTestCase {

    // MARK: - Fixtures

    /// Two sequences differing in exactly two places, far apart.
    private func twoEdits(_ count: Int) -> ([Int], [Int]) {
        let left = Array(0..<count)
        var right = left
        right[5] = -1
        right[count - 6] = -2
        return (left, right)
    }

    private func operationChecksum<T>(_ operations: [DiffOp<T>]) -> Int {
        operations.reduce(into: 0) { checksum, operation in
            switch operation {
            case .match: checksum &+= 1
            case .onlyInA: checksum &+= 3
            case .onlyInB: checksum &+= 7
            }
        }
    }

    private func summaryChecksum(_ result: CompareResult) -> Int {
        switch result {
        case .match: return 1
        case .cancelled: return -1
        case .mismatch(let summary):
            return summary.added &+ summary.removed &+ summary.changed &+ summary.blocks.count
        }
    }

    // MARK: - C2: line diff

    /// Just over the old 2001-line LCS cell cliff, with two edits. Pre-fix this
    /// was fast and wrong (1999 changed lines); post-fix it is fast and right.
    func testPerfDiff2001TwoEdits() {
        let (left, right) = twoEdits(2_001)
        PerfHarness.measure("diff_2001_two_edits", samples: 5, iterations: 10) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    /// Ten times bigger, same two edits — the shape a real "I changed two lines
    /// in a big config" compare has.
    func testPerfDiff20000TwoEdits() {
        let (left, right) = twoEdits(20_000)
        PerfHarness.measure("diff_20000_two_edits", samples: 5, iterations: 2) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    /// Every tenth line changed in 3000 lines: edit distance 600, comfortably
    /// inside the Myers ceiling, and the case the old cell limit destroyed
    /// completely (9 matches out of 3000).
    func testPerfDiff3000TenPercent() {
        let left = Array(0..<3_000)
        var right = left
        for index in stride(from: 0, to: right.count, by: 10) { right[index] = -index - 1 }
        PerfHarness.measure("diff_3000_ten_percent", samples: 5, iterations: 1) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    // MARK: - P3: block resemblance

    /// The workload `resemblancePercent` was rewritten for: a 1500-line CRLF pair
    /// whose difference is one contiguous 200-line changed block, so the block is
    /// ~10 000 characters a side and goes through the resemblance LCS whole.
    func testPerfCompareResemblance1500WithA200LineChangedBlock() {
        let (left, right) = resemblanceFixture(thai: false)
        PerfHarness.measure("compare_resemblance_1500_block200", samples: 5, iterations: 1) {
            summaryChecksum(TextComparator.compare(left, right, options: CompareOptions()))
        }
    }

    /// Same shape in Thai. Combining vowels and tone marks are their own UTF-16
    /// code units but were each folded into a grapheme cluster by the old
    /// `Array(String)`, which is the expensive part being removed.
    func testPerfCompareResemblance1500ThaiChangedBlock() {
        let (left, right) = resemblanceFixture(thai: true)
        PerfHarness.measure("compare_resemblance_1500_block200_thai", samples: 5, iterations: 1) {
            summaryChecksum(TextComparator.compare(left, right, options: CompareOptions()))
        }
    }

    private func resemblanceFixture(thai: Bool) -> (String, String) {
        var left: [String] = []
        var right: [String] = []
        left.reserveCapacity(1_500)
        right.reserveCapacity(1_500)
        for index in 0..<1_500 {
            let line = thai
                ? "อินเทอร์เฟซ \(index) คำอธิบาย พอร์ตผู้ใช้ \(index % 97)"
                : "interface GigabitEthernet1/0/\(index) description user-port-\(index % 97)"
            left.append(line)
            right.append(index >= 600 && index < 800
                         ? line + (thai ? " เปลี่ยนแปลง" : " changed-suffix")
                         : line)
        }
        return (left.joined(separator: "\r\n"), right.joined(separator: "\r\n"))
    }
}
