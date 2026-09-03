//
//  PerfHarnessFoldingTests.swift
//  Before/after workloads for the folding / gutter / line-index layer.
//
//  Written against the API as it exists BEFORE the audit fixes, because the
//  orchestrator runs this class on the pre-fix commit too. Nothing here may
//  reference a symbol introduced by a fix — so the *cursor* form of the
//  sequential workload is measured in `FoldingAuditPerfEvidenceTests`, which
//  only exists after the fix. Pair them by name when reading the numbers:
//
//    textlineindex_sequential_1000_lookups_128KB → textlineindex_cursor_1000_lookups_128KB
//    gutter_foldLineSpans_40_folds               → gutter_foldLineSpans_40_folds_batched
//
//  Fixture sizes are chosen so a Debug (-Onone) run of the whole class stays
//  under a minute. The audit measured `lineAndStart` at 4.6 ms for a 5 MB
//  document optimised; unoptimised the same scan is ~600 ms, which makes a
//  literal "1000 lookups over 5 MB" workload a four-minute Debug measurement.
//  The shape being measured — O(offset) per lookup, repeated — is identical at
//  128 KB, and the Release column is the one to compare against real timings.
//
//  `textlineindex_cold_200_lookups_128KB` is the regression guard on the scanner
//  itself: the fix widened its break set (CR, U+0085, U+2028, U+2029) and that
//  must not have cost the LF fast path anything. Its checksum is over LF-only
//  text, so it is unchanged by that widening.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessFoldingTests: XCTestCase {

    // MARK: - Fixtures

    /// ~128 KB of LF-terminated text, 16 UTF-16 units per line.
    static let smallSource: NSString = {
        String(repeating: "0123456789abcde\n", count: 128 * 1024 / 16) as NSString
    }()

    /// ~500 KB of source containing 40 foldable brace blocks, spread evenly.
    static func foldableSource() -> String {
        var text = ""
        let filler = "    let value = 0\n"
        for i in 0..<40 {
            text += "func block\(i)() {\n"
            text += String(repeating: filler, count: 3)
            text += "}\n"
            text += String(repeating: "// padding padding padding padding\n", count: 350)
        }
        return text
    }

    // MARK: - TextLineIndex

    /// The caret sitting near the end of a file and moving one unit at a time —
    /// which is what typing does. Every one of these is an O(offset) scan from
    /// the start, and the editor performs four to five of them per keystroke.
    func testPerfTextLineIndexSequentialLookups() {
        let text = Self.smallSource
        let base = text.length - 2000
        PerfHarness.measure("textlineindex_sequential_1000_lookups_128KB", samples: 3, iterations: 1) {
            var checksum = 0
            for step in 0..<1000 {
                checksum &+= TextLineIndex.lineAndStart(in: text, at: base + step).line
            }
            return checksum
        }
    }

    /// The same scanner at 200 scattered offsets — the guard on its own per-unit
    /// cost, which the widened break set must not have raised.
    func testPerfTextLineIndexColdLookups() {
        let text = Self.smallSource
        let offsets = stride(from: 0, to: text.length, by: max(1, text.length / 200)).map { $0 }
        PerfHarness.measure("textlineindex_cold_200_lookups_128KB", samples: 3, iterations: 1) {
            offsets.reduce(0) { $0 &+ TextLineIndex.lineAndStart(in: text, at: $1).line }
        }
    }

    // MARK: - Gutter fold spans

    /// What the gutter did on every redraw while any modified-since-save bar was
    /// showing: one whole-document line-number scan per collapsed fold.
    func testPerfGutterFoldLineSpans40Folds() {
        let storage = NSTextStorage(string: Self.foldableSource())
        let fm = FoldingManager()
        // Fold back-to-front so the earlier offsets stay valid.
        for range in fm.foldableRanges(in: storage.string as NSString).reversed() {
            fm.fold(range: range, in: storage)
        }
        XCTAssertEqual(fm.regions.count, 40, "fixture must actually fold, or this measures nothing")

        PerfHarness.measure("gutter_foldLineSpans_40_folds", samples: 5, iterations: 1) {
            let display = storage.string as NSString
            var checksum = 0
            for region in fm.regions {
                guard region.displayLocation >= 0, region.displayLocation < display.length,
                      region.hiddenLineCount > 0 else { continue }
                checksum &+= TextLineIndex.lineNumber(in: display, at: region.displayLocation)
            }
            return checksum
        }

        // What it does now: one pass answering all 40 offsets. Same checksum, by
        // construction — the fold set and the text are identical.
        PerfHarness.measure("gutter_foldLineSpans_40_folds_batched", samples: 5, iterations: 1) {
            let display = storage.string as NSString
            let usable = fm.regions.filter {
                $0.displayLocation >= 0 && $0.displayLocation < display.length && $0.hiddenLineCount > 0
            }
            return TextLineIndex.lineNumbers(in: display, at: usable.map(\.displayLocation))
                .reduce(0, &+)
        }
    }
}
