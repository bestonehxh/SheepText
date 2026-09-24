//
//  PerfHarnessAudit2CompareTests.swift
//  Workloads for the compare findings of the 17 September 2026 audit.
//
//  NOTE ON CHECKSUMS. The three `diff_*_scattered` workloads MOVE between the
//  pre-fix and post-fix runs, deliberately: before C4 the work budget was
//  divided by the input size, so the exact search bailed and `prefixSuffixDiff`
//  returned ~2n interleaved add/remove ops instead of a diff. A different
//  checksum there IS the fix. `diff_2000_disjoint` must NOT move — it still
//  falls back, and its cost is the "a hopeless pair spends ~24 ms proving it"
//  budget being kept.
//
//  NOTE ON PRE-FIX RUNS. `compare_keystroke_rebuild_*` and
//  `compare_apply_second_display_*` drive API that did not exist before this
//  branch (`CompareBenchmarkSeam.keystrokeRebuildChecksum`,
//  `CompareStorageWrite`), so they cannot be run on the old commit. The
//  before-numbers for them are in the audit report (CP5: 124 ms per rebuild at
//  200 k lines; CP2: 14.5 ms of filler attribute per apply at 200 k rows).
//

import AppKit
import XCTest
@testable import SheepText

final class PerfHarnessAudit2CompareTests: XCTestCase {

    // MARK: - Fixtures

    /// `count` lines with `edits` of them changed, spread evenly so neither the
    /// prefix nor the suffix trim absorbs them.
    private func scattered(count: Int, edits: Int) -> ([Int], [Int]) {
        let left = Array(0..<count)
        var right = left
        let step = max(1, count / edits)
        for index in 0..<edits {
            right[min(count - 1, index * step + step / 2)] = -(index + 1)
        }
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

    private func configLines(_ count: Int) -> [String] {
        (0..<count).map { "interface GigabitEthernet1/0/\($0) description user-port-\($0 % 97)" }
    }

    // MARK: - C4: the exact ceiling at scale

    /// The headline shape: a 200 000-line config with forty edited lines. Before
    /// C4 this fell back (`maxD` was 60) and reported 190 243 changed rows.
    func testPerfDiff200kFortyScatteredEdits() {
        let (left, right) = scattered(count: 200_000, edits: 40)
        PerfHarness.measure("diff_200k_40_scattered", samples: 5, iterations: 1) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    /// Edit distance 4000 — above the old memory ceiling as well as the old
    /// budget, and the most expensive shape the exact search is now allowed to
    /// take on. This is the number that pins "how slow is being right".
    func testPerfDiff200kTwoThousandScatteredEdits() {
        let (left, right) = scattered(count: 200_000, edits: 2_000)
        PerfHarness.measure("diff_200k_2000_scattered", samples: 5, iterations: 1) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    /// 20 000 lines / 500 edits: `maxD` was 600 here, one edit short either way.
    func testPerfDiff20kFiveHundredScatteredEdits() {
        let (left, right) = scattered(count: 20_000, edits: 500)
        PerfHarness.measure("diff_20k_500_scattered", samples: 5, iterations: 1) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    /// The pair that must STILL fall back, and must still do it quickly: two
    /// disjoint 2000-line files. Checksum and cost both have to hold.
    func testPerfDiff2000Disjoint() {
        let left = Array(0..<2_000)
        let right = Array(10_000..<12_000)
        PerfHarness.measure("diff_2000_disjoint", samples: 5, iterations: 1) {
            operationChecksum(DiffCalc.diff(left, right, equal: ==))
        }
    }

    // MARK: - CP5: only one side moves per keystroke

    /// Twenty settled keystrokes on the right-hand document of a 200 000-line
    /// compare. Both documents used to be split and FNV-hashed from scratch on
    /// every one of them.
    func testPerfKeystrokeRebuild200k() {
        let base = configLines(200_000)
        let left = base.joined(separator: "\n")
        let rightVariants = (0..<20).map { step -> String in
            var lines = base
            lines[100_000] = "interface GigabitEthernet1/0/100000 description edited-\(step)"
            return lines.joined(separator: "\n")
        }
        _ = CompareBenchmarkSeam.rowHistogram(left: left, right: rightVariants[0])
        PerfHarness.measure("compare_keystroke_rebuild_200k", samples: 5, iterations: 1) {
            CompareBenchmarkSeam.keystrokeRebuildChecksum(left: left, rightVariants: rightVariants)
        }
    }

    /// Same at the size a real router config lands on.
    func testPerfKeystrokeRebuild20k() {
        let base = configLines(20_000)
        let left = base.joined(separator: "\n")
        let rightVariants = (0..<20).map { step -> String in
            var lines = base
            lines[10_000] = "interface GigabitEthernet1/0/10000 description edited-\(step)"
            return lines.joined(separator: "\n")
        }
        _ = CompareBenchmarkSeam.rowHistogram(left: left, right: rightVariants[0])
        PerfHarness.measure("compare_keystroke_rebuild_20k", samples: 5, iterations: 1) {
            CompareBenchmarkSeam.keystrokeRebuildChecksum(left: left, rightVariants: rightVariants)
        }
    }

    // MARK: - C1 / CP2: applying a second display over the first

    /// The main-queue half of `applyCompareDisplay`: write a display over a
    /// storage that already holds a different one. The filler attribute is
    /// reconciled over the WHOLE storage (C1) — as a diff, which is what keeps
    /// this off the 14.5 ms the blind rewrite costs at this size (CP2).
    @MainActor
    func testPerfApplySecondDisplay20k() {
        let base = configLines(20_000)
        let left = base.joined(separator: "\n")
        var rightLines = base
        for index in stride(from: 0, to: rightLines.count, by: 7) {
            rightLines[index] += " changed"
        }
        let rightA = rightLines.joined(separator: "\n")
        rightLines[19_000] = "interface GigabitEthernet1/0/19000 description moved-later"
        let rightB = rightLines.joined(separator: "\n")

        let first = materialise(left: left, right: rightA)
        let second = materialise(left: left, right: rightB)
        let storage = NSTextStorage()
        CompareStorageWrite.perform(display: first.text, fillerRuns: first.runs,
                                    into: storage, willReplaceText: {})

        PerfHarness.measure("compare_apply_second_display_20k", samples: 5, iterations: 1) {
            // Alternate, so every timed call is a real second apply rather than
            // a no-op over a storage that already holds the answer.
            CompareStorageWrite.perform(display: second.text, fillerRuns: second.runs,
                                        into: storage, willReplaceText: {})
            CompareStorageWrite.perform(display: first.text, fillerRuns: first.runs,
                                        into: storage, willReplaceText: {})
            return storage.length
        }
    }

    @MainActor
    private func materialise(left: String, right: String) -> (text: NSAttributedString, runs: [NSRange]) {
        let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: true)
        let attributed = NSMutableAttributedString(string: probe.displayText)
        for range in probe.fillerRanges {
            attributed.addAttribute(.isFillerLine, value: true, range: range)
        }
        return (attributed,
                CompareStorageWrite.fillerRuns(rowRanges: probe.rows.map(\.range),
                                               isFiller: probe.rows.map(\.isFiller)))
    }
}
