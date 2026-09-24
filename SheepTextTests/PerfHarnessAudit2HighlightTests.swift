//
//  PerfHarnessAudit2HighlightTests.swift
//  Before/after workloads for the highlight findings of the 17 September 2026
//  audit.
//
//    saved_line_marks_900k              ← TP4: the modified-since-save diff
//    apply_highlight_cache_hit_540k     ← HP1: a tab switch onto a cached tab
//
//  Both are written against the API as it was BEFORE the fixes, so the
//  orchestrator can run them on the base commit.
//
//  Debug-only, unlike `PerfHarnessViewportTests`: `EditorRepresentable` and its
//  coordinator are file-private, so the only way in is
//  `EditorViewAuditSeam`, which is `#if DEBUG`. What both workloads spend
//  their time on — stdlib string hashing, `components(separatedBy:)` and
//  dictionary inserts — is compiled stdlib either way, so a Debug before/after
//  is a fair comparison; the absolute numbers are not Release numbers.
//

import AppKit
import XCTest
@testable import SheepText

#if DEBUG

@MainActor
final class PerfHarnessAudit2HighlightTests: XCTestCase {

    // MARK: - TP4: the modified-since-save diff

    /// ~900 KB / 52 000 lines — the size the audit measured the per-pause
    /// garbage at.
    private static let savedText: String = (0..<52_000)
        .map { "    let value\($0) = \($0)   // measured line" }
        .joined(separator: "\n") + "\n"

    /// The same file after a typing burst: one line edited, one inserted.
    private static let currentText: String = {
        var lines = savedText.components(separatedBy: "\n")
        lines[10] = "    let value10 = 999   // edited"
        lines.insert("    let inserted = 0", at: 26_000)
        return lines.joined(separator: "\n")
    }()

    /// 350 ms after every typing burst, on a utility thread, this split and
    /// interned BOTH documents. The saved side only moves when the file is
    /// saved, so it is memoised now.
    func testPerfSavedLineMarks() {
        PerfHarness.measure("saved_line_marks_900k", samples: 5) { () -> Int in
            let marks = EditorViewAuditSeam.savedLineMarks(
                saved: Self.savedText, current: Self.currentText
            )
            return marks.map { "\($0.key):\($0.value)" }.sorted().joined().hashValue
        }
    }

    /// The same diff with the memo thrown away each time — which is exactly
    /// what every call did before TP4, so this is the "before" number in the
    /// same run. (It is the one workload here that does not compile on the base
    /// commit: `clearSavedLineMarkMemo` is part of the fix.)
    func testPerfSavedLineMarksWithoutTheMemo() {
        PerfHarness.measure("saved_line_marks_900k_cold", samples: 5) { () -> Int in
            EditorViewAuditSeam.clearSavedLineMarkMemo()
            let marks = EditorViewAuditSeam.savedLineMarks(
                saved: Self.savedText, current: Self.currentText
            )
            return marks.map { "\($0.key):\($0.value)" }.sorted().joined().hashValue
        }
    }

    // MARK: - HP1: the run cache's key

    /// ~540 KB of Swift — the fixture the viewport redesign is quoted against.
    private static let swiftSource: String = {
        let line = "func value(_ input: Int) -> Int { let result = input * 2; return result } // probe 0\n"
        return String(repeating: line, count: 540_000 / (line as NSString).length)
    }()

    /// A tab switch onto a tab whose runs are already cached, and the apply
    /// every typing pause ends with. It should cost the paint (0.8 ms), not the
    /// file: the key used to be `String.hashValue` of the storage's bridged
    /// string, computed before the cache was even consulted.
    func testPerfApplyHighlightCacheHit() {
        let probe = EditorViewAuditSeam.Probe(text: Self.swiftSource, language: "swift")
        EditorViewAuditSeam.clearHighlightCache()
        EditorViewAuditSeam.storeHighlight(for: probe.document)

        // The workload is only meaningful if this really is a cache hit.
        SyntaxEngine.resetHighlightPassCountForTesting()
        probe.applyHighlightNow()
        XCTAssertEqual(SyntaxEngine.highlightPassCount, 0,
                       "the entry was not served — this is measuring a parse, not a cache hit")

        PerfHarness.measure("apply_highlight_cache_hit_540k_swift", samples: 5) { () -> Int in
            probe.applyHighlightNow()
            return probe.runs.count &+ (probe.viewportRange?.length ?? 0)
        }
    }

    /// The key the apply above used to build, on its own: `String.hashValue`
    /// of `NSTextStorage.string`. The bridge is free; the hash is not — Swift's
    /// foreign path transcodes UTF-16 to UTF-8 as it hashes. This is the
    /// "before" number in the same run, and it was computed before the cache
    /// was consulted, so it was the floor for a HIT.
    func testPerfTheOldCacheKey() {
        let storage = NSTextStorage(string: Self.swiftSource)
        PerfHarness.measure("apply_highlight_old_cache_key_540k_swift", samples: 5) { () -> Int in
            storage.string.hashValue == 0 ? 1 : 0
        }
    }
}

#endif
