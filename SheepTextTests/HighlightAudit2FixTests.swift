//
//  HighlightAudit2FixTests.swift
//  Regressions for the highlight findings of the 17 September 2026 audit.
//
//  The apply layer's contract is one sentence: over the painted window, what
//  the layout manager draws is exactly what `highlightRuns` says. Every finding
//  here is a way that stopped being true — an edit that left a hole (H1), a
//  result painted onto the wrong document (H2), a scroll gap recorded as
//  painted (H4), runs that no longer describe the text (H5, H6), and a paint
//  nothing scrubbed once highlighting turned itself off (H7).
//

import AppKit
import XCTest
@testable import SheepText

#if DEBUG

@MainActor
private enum Audit2Fixture {

    static let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
    static let string = HighlightStyleTable.styleID(forCapture: "string")

    /// 2000 numbered lines, 20 UTF-16 units each — far more text than a 200 pt
    /// viewport can show, so "painted" and "on screen" are different sets.
    static let longSource: String = (0..<2000)
        .map { String(format: "line %04d aaaa bbbb", $0) }
        .joined(separator: "\n") + "\n"

    /// One run per line, so every painted character carries a token colour.
    static func runsForEveryLine(in text: String) -> [HighlightRun] {
        var runs: [HighlightRun] = []
        let ns = text as NSString
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if line.length > 1 {
                runs.append(HighlightRun(location: line.location, length: line.length - 1,
                                         style: runs.count.isMultiple(of: 2) ? keyword : string))
            }
            location = NSMaxRange(line)
        }
        return runs
    }

    /// The invariant, asserted character by character over `range`: the colour
    /// on the layout manager is the one the run list resolves to, and an
    /// unstyled character carries the editor's base colour rather than nothing.
    static func assertPaintMatchesRuns(
        _ probe: EditorViewAuditSeam.Probe,
        in range: NSRange,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let colors = probe.paintedForegroundColors()
        let base = probe.baseForegroundColor
        for index in range.location..<NSMaxRange(range) {
            let style = HighlightRunList.style(at: index, in: probe.runs)
            let expected = HighlightStyleTable.color(style, isDark: probe.isDark) ?? base
            XCTAssertEqual(
                colors[index], expected,
                "\(message) — character \(index) of \(probe.storage.string)",
                file: file, line: line
            )
        }
    }

    static func whole(_ probe: EditorViewAuditSeam.Probe) -> NSRange {
        NSRange(location: 0, length: probe.storage.length)
    }
}

// MARK: - H1: an edit must not leave a hole in the paint

/// AppKit does NOT stretch a temporary-attribute run across an insertion inside
/// it — it splits the run and leaves the inserted characters bare — while
/// `HighlightRunList.shifting` stretches both the runs and the painted window.
/// So the coordinator believed it had painted characters that carry nothing,
/// and every character typed inside a token rendered in the base colour until
/// the rehighlight debounce fired (0.3 s on a large file).
@MainActor
final class HighlightEditHolePaintTests: XCTestCase {

    private func probe(_ text: String, runs: [HighlightRun]) -> EditorViewAuditSeam.Probe {
        let probe = EditorViewAuditSeam.Probe(text: text)
        probe.setRuns(runs)
        return probe
    }

    /// The headline case: type a character in the middle of a token.
    func testACharacterTypedInsideARunIsPaintedWithThatRunsColour() {
        let probe = probe("let value = 1\n",
                          runs: [HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword)])

        probe.applyEdit(range: NSRange(location: 6, length: 0), with: "X")

        let expected = HighlightStyleTable.color(Audit2Fixture.keyword, isDark: probe.isDark)
        XCTAssertEqual(probe.paintedForegroundColors()[6], expected,
                       "the inserted character was left with no token colour")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "insertion in the middle of a run")
    }

    func testAnInsertionAtARunsStartIsPainted() {
        let probe = probe("let value = 1\n",
                          runs: [HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword)])
        probe.applyEdit(range: NSRange(location: 4, length: 0), with: "X")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "insertion at a run's start")
    }

    /// The mirror image: AppKit may extend the run's temporary attribute over a
    /// character that `shifting` leaves outside the run, so the new character
    /// would wear a colour it has no right to.
    func testAnInsertionAtARunsEndIsPainted() {
        let probe = probe("let value = 1\n",
                          runs: [HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword)])
        probe.applyEdit(range: NSRange(location: 9, length: 0), with: "X")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "insertion at a run's end")
    }

    func testAnInsertionBetweenTwoRunsIsPainted() {
        let probe = probe(
            "let value = 1\n",
            runs: [
                HighlightRun(location: 0, length: 3, style: Audit2Fixture.keyword),
                HighlightRun(location: 4, length: 5, style: Audit2Fixture.string)
            ]
        )
        probe.applyEdit(range: NSRange(location: 3, length: 1), with: "  ")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "replacement between two runs")
    }

    func testAMultiCharacterPasteInsideARunIsPainted() {
        let probe = probe("let value = 1\n",
                          runs: [HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword)])
        probe.applyEdit(range: NSRange(location: 7, length: 0), with: "ABCDEFGH")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "multi-character paste inside a run")
    }

    /// Typing over a selection: same length in, different text. `shifting`
    /// keeps the run, AppKit keeps its own idea of the attribute run.
    func testReplacingASelectionInsideARunIsPainted() {
        let probe = probe("let value = 1\n",
                          runs: [HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword)])
        probe.applyEdit(range: NSRange(location: 5, length: 3), with: "XYZ")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "selection replaced inside a run")
    }

    /// A deletion closes the gap on both sides, so there is nothing to repair —
    /// pinned so a future "repaint everything" fix cannot hide behind it.
    func testADeletionJoiningTwoRunsLeavesThePaintCorrect() {
        let probe = probe(
            "let value = 1\n",
            runs: [
                HighlightRun(location: 0, length: 3, style: Audit2Fixture.keyword),
                HighlightRun(location: 4, length: 5, style: Audit2Fixture.string)
            ]
        )
        probe.applyEdit(range: NSRange(location: 3, length: 1), with: "")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "deletion joining two runs")
    }

    /// Several edits land before one `textDidChange` (multi-cursor typing is
    /// one `replaceCharacters` per cursor, applied back to front), so a hole
    /// recorded by an earlier edit has to move with the later ones.
    func testSeveralEditsBeforeOnePaintAreAllRepaired() {
        let probe = probe(
            "let value = 1\nlet other = 2\n",
            runs: [
                HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword),
                HighlightRun(location: 18, length: 5, style: Audit2Fixture.string)
            ]
        )
        // Back to front, the way `insertText(_:atRanges:)` applies them.
        probe.storage.replaceCharacters(in: NSRange(location: 20, length: 0), with: "Z")
        probe.applyEdit(range: NSRange(location: 6, length: 0), with: "Z")
        Audit2Fixture.assertPaintMatchesRuns(probe, in: Audit2Fixture.whole(probe),
                                             "two edits, one paint")
    }
}

// MARK: - H2 / H6: a result may only be painted onto the text it was computed for

@MainActor
final class HighlightResultOwnershipTests: XCTestCase {

    /// One text view serves every tab, so `boundTextView === textView` is
    /// always true and the completion's guard said nothing about WHICH
    /// document the runs describe. A tab switch onto a cached tab does not bump
    /// `highlightGeneration` either, so the window was unbounded: the previous
    /// tab's token boundaries were painted onto this one and stayed there.
    func testAHighlightPassForTheOutgoingTabIsNotPaintedOntoTheIncomingOne() {
        let source = String(
            repeating: "func value(_ input: Int) -> Int { return input * 2 }\n", count: 200
        )
        let probe = EditorViewAuditSeam.Probe(text: source, language: "swift")
        EditorViewAuditSeam.clearHighlightCache()
        let outgoing = probe.document.id

        probe.applyHighlightNow()          // the parse for tab A is now in flight
        probe.swapDocument(text: "plain words, no grammar at all\n")
        probe.cancelPendingHighlightWork()

        // Let A's result land. Nothing else is scheduled, so whatever the runs
        // are afterwards, A's completion is the only thing that could have set
        // them.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(probe.runs.isEmpty,
                      "the outgoing tab's runs were installed on the incoming document")
        XCTAssertEqual(probe.paintedCharacterCount(), 0,
                       "the outgoing tab's colours were painted onto the incoming document")
        XCTAssertTrue(EditorViewAuditSeam.highlightCacheContains(outgoing),
                      "the parse that was dropped for this pane should still be cached for its own tab")
    }

    /// Same shape, one document: a reload from disk replaces the storage
    /// without changing `document.id`, so the document check alone would let a
    /// pass computed against the old bytes through.
    func testAHighlightPassIsDroppedWhenTheStorageIsReplacedUnderIt() {
        let source = String(
            repeating: "func value(_ input: Int) -> Int { return input * 2 }\n", count: 200
        )
        let probe = EditorViewAuditSeam.Probe(text: source, language: "swift")
        EditorViewAuditSeam.clearHighlightCache()

        probe.applyHighlightNow()
        // What `documentReloadObserver` does: new text, then tell the coordinator.
        probe.replaceStorageWholesale(with: "let only = 1\n")
        probe.cancelPendingHighlightWork()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(probe.runs.isEmpty,
                      "runs computed against the pre-reload text were installed anyway")
    }

    /// H6 — the first-paint snippet. Its completion checked the document, the
    /// view, the compare peer and the folds, but not the generation, so the
    /// offsets it adds were the ones from before the keystroke.
    func testTheFirstPaintSnippetIsDroppedWhenTheTextMovedUnderIt() {
        let source = String(
            repeating: "func value(_ input: Int) -> Int { return input * 2 }\n", count: 200
        )
        let probe = EditorViewAuditSeam.Probe(text: source, language: "swift")
        EditorViewAuditSeam.clearHighlightCache()
        probe.document.precomputedSyntaxHighlight = nil

        probe.applyCachedHighlightOrDefer()     // snippet pass in flight
        probe.applyEdit(range: NSRange(location: 0, length: 0), with: "// a comment line\n")
        probe.cancelPendingHighlightWork()      // ...and nothing else may run

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(probe.runs.isEmpty,
                      "the snippet was painted at offsets the edit had already moved")
    }
}

// MARK: - H4: the painted window may not span a gap it never painted

@MainActor
final class HighlightPaintedWindowTests: XCTestCase {

    /// `NSUnionRange` of two disjoint ranges covers the gap between them, and
    /// the four-viewport trim only fires past a six-screen jump — so any jump
    /// of one to six screens recorded an unpainted band as painted, and the
    /// early return refused to paint it on the way back.
    func testScrollingBackOverAGapRepaintsIt() throws {
        let probe = EditorViewAuditSeam.Probe(text: Audit2Fixture.longSource)
        probe.setRuns(Audit2Fixture.runsForEveryLine(in: Audit2Fixture.longSource))

        // The painted window starts as roughly three screens at the top. A jump
        // of two screens is disjoint from it but well short of the six the
        // four-viewport trim needs, so the union silently swallowed the gap.
        probe.scroll(toY: 1000)
        probe.scroll(toY: 500)    // back into the middle of the band jumped over

        let viewport = try XCTUnwrap(probe.viewportRange)
        Audit2Fixture.assertPaintMatchesRuns(
            probe, in: viewport,
            "the band scrolled over was recorded as painted but never was"
        )
    }

    /// The overlapping case still coalesces — a scroll of half a screen must
    /// not throw away and redo the whole window.
    func testAnOverlappingScrollStillPaintsOnlyTheDelta() throws {
        let probe = EditorViewAuditSeam.Probe(text: Audit2Fixture.longSource)
        probe.setRuns(Audit2Fixture.runsForEveryLine(in: Audit2Fixture.longSource))
        let firstViewport = try XCTUnwrap(probe.viewportRange)

        EditorViewAuditSeam.viewportPaintCount = 0
        probe.scroll(toY: 100)
        XCTAssertLessThan(
            EditorViewAuditSeam.lastPaintedCharacterCount, firstViewport.length,
            "an overlapping scroll repainted the whole viewport instead of the strip that arrived"
        )
    }
}

// MARK: - H5: runs that no longer describe the text may not be painted

@MainActor
final class HighlightStaleRunsTests: XCTestCase {

    /// With a fold collapsed, `storageDidEditCharacters` deliberately declines
    /// to shift the runs (display and full-text offsets differ, and an edit can
    /// even eat a placeholder). It also left them *trusted*, so a strip
    /// scrolled into view before the debounce was painted from pre-edit runs at
    /// pre-edit offsets — every colour in it off by the edit's delta.
    func testAnEditUnderACollapsedFoldStopsTheStaleRunsFromBeingPainted() throws {
        let probe = EditorViewAuditSeam.Probe(text: Audit2Fixture.longSource)
        probe.setRuns(Audit2Fixture.runsForEveryLine(in: Audit2Fixture.longSource))
        probe.foldingManager.fold(range: NSRange(location: 2000, length: 200), in: probe.storage)
        probe.foldingDidChangeDisplayText()

        probe.applyEdit(range: NSRange(location: 0, length: 0), with: "abcdefgh")
        probe.scroll(toY: 2400)

        let viewport = try XCTUnwrap(probe.viewportRange)
        let colors = probe.paintedForegroundColors()
        for index in viewport.location..<NSMaxRange(viewport) {
            XCTAssertEqual(
                colors[index], probe.baseForegroundColor,
                "character \(index) was painted from runs that no longer describe the text"
            )
        }
    }

    /// ...and the next engine pass puts the colours back.
    func testAFreshRunListClearsTheStaleFlag() throws {
        let probe = EditorViewAuditSeam.Probe(text: Audit2Fixture.longSource)
        probe.setRuns(Audit2Fixture.runsForEveryLine(in: Audit2Fixture.longSource))
        probe.foldingManager.fold(range: NSRange(location: 2000, length: 200), in: probe.storage)
        probe.foldingDidChangeDisplayText()
        probe.applyEdit(range: NSRange(location: 0, length: 0), with: "abcdefgh")

        probe.setRuns(Audit2Fixture.runsForEveryLine(in: probe.document.text))
        probe.scroll(toY: 2400)

        let viewport = try XCTUnwrap(probe.viewportRange)
        let colors = probe.paintedForegroundColors()
        let painted = (viewport.location..<NSMaxRange(viewport))
            .filter { colors[$0] != probe.baseForegroundColor }
        XCTAssertFalse(painted.isEmpty, "a fresh run list never repainted any colour")
    }
}

// MARK: - TP4: the modified-since-save baseline is memoised, not re-derived

@MainActor
final class SavedLineMarkMemoTests: XCTestCase {

    /// The saved side of the diff is split and interned once and kept. The
    /// answer must not depend on whether the memo was warm, or on which
    /// baseline was in it a moment ago.
    func testAMemoisedBaselineGivesExactlyTheColdAnswer() {
        let cases: [(saved: String, current: String)] = [
            ("alpha\nbravo\ncharlie\n", "alpha\nbravo\ncharlie\n"),
            ("alpha\nbravo\ncharlie\n", "alpha\nXX\ncharlie\n"),
            ("alpha\nbravo\ncharlie\n", "alpha\nbravo\nbravo\ncharlie\n"),
            ("alpha\nbravo\ncharlie\n", "alpha\ncharlie\n"),
            ("same\nsame\nsame\n", "same\nsame\n"),
            ("", "brand new\n"),
            ("alpha\nbravo\n", ""),
            // CRLF: `components(separatedBy: "\n")` splits on the scalar, so
            // every line keeps a trailing CR — on both sides, and the memo must
            // not change that.
            ("alpha\r\nbravo\r\n", "alpha\r\nbravo\r\ncharlie\r\n")
        ]

        for (saved, current) in cases {
            EditorViewAuditSeam.clearSavedLineMarkMemo()
            let cold = EditorViewAuditSeam.savedLineMarks(saved: saved, current: current)

            let warm = EditorViewAuditSeam.savedLineMarks(saved: saved, current: current)
            XCTAssertEqual(cold, warm, "a warm memo changed the answer for \(saved) → \(current)")

            // A different baseline in between: the memo is one entry, so this
            // evicts it, and the key has to notice.
            _ = EditorViewAuditSeam.savedLineMarks(saved: "zulu\nyankee\n", current: "zulu\n")
            let afterForeign = EditorViewAuditSeam.savedLineMarks(saved: saved, current: current)
            XCTAssertEqual(cold, afterForeign,
                           "another document's baseline leaked into \(saved) → \(current)")
        }
    }

    /// Two baselines of the same length that differ in content must not be
    /// confused — the key is the hash as well as the length.
    func testTwoBaselinesOfEqualLengthAreToldApart() {
        EditorViewAuditSeam.clearSavedLineMarkMemo()
        let first = EditorViewAuditSeam.savedLineMarks(saved: "aaa\nbbb\n", current: "aaa\nbbb\nccc\n")
        let second = EditorViewAuditSeam.savedLineMarks(saved: "xxx\nyyy\n", current: "aaa\nbbb\nccc\n")
        XCTAssertEqual(first, [3: "added"])
        XCTAssertEqual(second, [1: "modified", 2: "modified", 3: "modified"])
    }
}

// MARK: - HP1: the run cache's identity is O(1), and still exact

@MainActor
final class HighlightCacheIdentityTests: XCTestCase {

    /// The key was a content hash of `fullText(from: storage)` — a bridged
    /// NSString, whose `hashValue` transcodes the whole document. It is
    /// `Document.revision` now; the entry must still be served.
    func testACachedRunListIsServedAtTheSameRevision() {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\n", language: "swift")
        let cached = [HighlightRun(location: 0, length: 3, style: Audit2Fixture.keyword)]
        EditorViewAuditSeam.clearHighlightCache()
        EditorViewAuditSeam.storeHighlight(for: probe.document, runs: cached)
        probe.setRuns([])

        probe.applyHighlightNow()

        XCTAssertEqual(probe.runs, cached, "the entry for this exact revision was not served")
    }

    /// ...and an edit that does not change the document's LENGTH must still
    /// miss, which is the whole reason the revision and not just the length is
    /// in the key.
    func testALengthPreservingEditInvalidatesTheCachedRunList() {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\n", language: "swift")
        EditorViewAuditSeam.clearHighlightCache()
        EditorViewAuditSeam.storeHighlight(
            for: probe.document,
            runs: [HighlightRun(location: 0, length: 3, style: Audit2Fixture.keyword)]
        )
        probe.setRuns([])

        probe.applyEdit(range: NSRange(location: 10, length: 3), with: "999")
        probe.cancelPendingHighlightWork()
        probe.applyHighlightNow()

        XCTAssertTrue(probe.runs.isEmpty,
                      "runs from before the edit were served for text that has moved")
    }
}

// MARK: - H7: large-file mode has to scrub what it stops maintaining

@MainActor
final class HighlightLargeFileModeTests: XCTestCase {

    /// Pasting past `LargeFilePolicy.characterThreshold` flips large-file mode
    /// on immediately. From there both the paint and the rehighlight return at
    /// their first guard, and nothing scrubbed the temporary attributes already
    /// on the layout manager — AppKit stretched and split them across the
    /// pasted text and they stayed until the tab was switched away and back.
    func testCrossingTheLargeFileThresholdScrubsThePaint() {
        let probe = EditorViewAuditSeam.Probe(text: "let value = 1\n")
        probe.setRuns([HighlightRun(location: 4, length: 5, style: Audit2Fixture.keyword)])
        XCTAssertNotNil(probe.paintedForegroundColor(at: 4), "nothing was painted to begin with")

        let huge = String(repeating: "x", count: LargeFilePolicy.characterThreshold)
        probe.applyEdit(range: NSRange(location: 13, length: 0), with: huge)

        XCTAssertTrue(probe.document.isLargeFileModeActive,
                      "the paste did not cross the threshold — the fixture is wrong")
        XCTAssertNil(probe.paintedForegroundColor(at: 4),
                     "the paint from before the paste is still on the layout manager")
        XCTAssertTrue(probe.runs.isEmpty,
                      "the run list is still resident for a document nothing will highlight")
    }
}

#endif
