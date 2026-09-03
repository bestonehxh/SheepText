//
//  PerfHarnessEditorCompareTests.swift
//  Before/after workloads for the compare DISPLAY layer (audit findings C5/P2
//  and C1). Each test prints one `PERF {...}` JSON line per workload; grep them
//  out of the xcodebuild log and diff the medians.
//
//  NOTE ON CHECKSUMS. `compare_realText_*` checksums must not move: the fix
//  swapped a `paragraphRange` walk for an LF scan, and on text without a stray
//  CR the two agree exactly — that is the point of the workload. The
//  `compare_rows_*` checksums must not move either; the row shapes are pinned
//  by EditorCompareAuditFixTests.
//
//  Not measured here: the word-level diff (P1). It is only reachable through a
//  seam that does not exist before the fix, and a workload naming it would stop
//  this whole class compiling on the pre-fix commit. Its before/after numbers
//  are in the fix report, measured with a standalone benchmark.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessEditorCompareTests: XCTestCase {

    // MARK: - Fixtures

    private func ciscoConfig(lines: Int) -> [String] {
        (0..<lines).map { i -> String in
            switch i % 5 {
            case 0: return "interface GigabitEthernet1/0/\(i)"
            case 1: return " description user-port-\(i)"
            case 2: return " switchport access vlan \(i % 4094 + 1)"
            case 3: return " spanning-tree portfast"
            default: return "!"
            }
        }
    }

    /// A compare display as `applyCompareDisplay` materialises it: the rows
    /// joined with "\n", every seventh row a blank filler carrying
    /// `.isFillerLine` over its whole range.
    private func displayStorage(rows: [String], ending: String) -> NSTextStorage {
        var lines: [String] = []
        var fillers: [Int] = []
        for (index, row) in rows.enumerated() {
            if index % 7 == 6 {
                fillers.append(lines.count)
                lines.append("")
            }
            lines.append(ending == "\r\n" ? row + "\r" : row)
        }
        let text = lines.joined(separator: "\n") + "\n"
        let storage = NSTextStorage(string: text)
        var location = 0
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length + 1
            if fillers.contains(index) {
                storage.addAttribute(.isFillerLine, value: true,
                                     range: NSRange(location: location, length: length))
            }
            location += length
        }
        return storage
    }

    // MARK: - C5 / P2: realText runs on every keystroke in compare mode

    /// The per-keystroke path. `realText(from:)` used to make one
    /// `NSString.paragraphRange` round trip per line, on the main actor, for
    /// every character typed in a compare pane.
    func testPerfRealTextOnAFillerLadenDisplay() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let store = displayStorage(rows: ciscoConfig(lines: 1_500), ending: "\n")
        PerfHarness.measure("compare_realText_1500_lines", samples: 5, iterations: 20) {
            (view.realText(from: store) as NSString).length
        }
    }

    /// Same shape with CRLF rows, which is what the configs this editor targets
    /// actually look like.
    func testPerfRealTextOnACRLFDisplay() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let store = displayStorage(rows: ciscoConfig(lines: 1_500), ending: "\r\n")
        PerfHarness.measure("compare_realText_1500_lines_crlf", samples: 5, iterations: 20) {
            (view.realText(from: store) as NSString).length
        }
    }

    // MARK: - C1: one build mode

    /// The audit's 600-line case: one line inserted near the top, one deleted
    /// near the bottom. The pane rows and the header counts both come from here
    /// now; the header used to ask for a different, index-aligned mode that
    /// reported ~400 changed rows for this input.
    func testPerfRows600TwoEdits() {
        var right = ciscoConfig(lines: 600)
        right.insert("vlan 4000 name inserted-here", at: 100)
        right.remove(at: 500)
        let l = ciscoConfig(lines: 600).joined(separator: "\n")
        let r = right.joined(separator: "\n")
        PerfHarness.measure("compare_rows_600_two_edits", samples: 5, iterations: 5) {
            CompareBenchmarkSeam.rowHistogram(left: l, right: r).reduce(0, &+)
        }
    }

    /// A 1500-line config with a genuine 20-line block move plus scattered
    /// edits — the input `detectMovedRows` walks. The move detector now filters
    /// short/blank keys and bounds its search window, which is work it did not
    /// do before; this workload is what says whether that costs anything.
    func testPerfRows1500WithAMovedBlock() {
        let left = ciscoConfig(lines: 1_500)
        var right = left
        for index in stride(from: 7, to: right.count, by: 20) { right[index] += " changed" }
        let block = Array(right[100..<120])
        right.removeSubrange(100..<120)
        right.append(contentsOf: block)
        let l = left.joined(separator: "\n")
        let r = right.joined(separator: "\n")
        PerfHarness.measure("compare_rows_1500_moved_block", samples: 5, iterations: 1) {
            CompareBenchmarkSeam.rowHistogram(left: l, right: r).reduce(0, &+)
        }
    }
}
