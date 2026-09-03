//
//  FoldingAuditFixTests.swift
//  Regression tests for the folding / gutter / line-index / find-bar audit.
//
//  Every test here failed before the corresponding fix. The findings are
//  labelled with their audit IDs (T…/U… from the audit reports).
//

import AppKit
import XCTest
@testable import SheepText

// MARK: - T1 / U1: fold regions must survive user edits

@MainActor
final class FoldRegionEditTrackingTests: XCTestCase {

    /// Four lines, the first three of which form a foldable brace block.
    private func source(ending: String) -> String {
        [
            "func outer() {",
            "    let a = 1",
            "}",
            "let tail = 3",
            ""
        ].joined(separator: ending)
    }

    private func foldFirstBlock(_ fm: FoldingManager, _ store: NSTextStorage) throws {
        let range = try XCTUnwrap(
            fm.foldableRange(onLine: 1, displayText: store.string as NSString),
            "fixture is not foldable — the test would pass vacuously"
        )
        fm.fold(range: range, in: store)
        XCTAssertEqual(fm.regions.count, 1)
    }

    private func assertNoPlaceholder(_ text: String, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0xFFFC },
                       "reconstructed text still contains U+FFFC. \(message)",
                       file: file, line: line)
    }

    // The exact repro from the audit: type one character at the very top of the
    // document while a fold is collapsed below it. `fullText` spliced at a stale
    // offset, dropping a character and leaving the attachment char in the text
    // that goes to `document.text` → the draft → disk.
    func testInsertionAboveAFoldDoesNotCorruptFullText() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)

        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")

        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, "X" + src)
    }

    func testInsertionAboveAFoldOnCRLFSource() throws {
        let fm = FoldingManager()
        let src = source(ending: "\r\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)

        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")

        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, "X" + src)
    }

    func testMultiLinePasteAboveTwoFoldsKeepsBothRegionsAligned() throws {
        let fm = FoldingManager()
        let src = """
        func one() {
            let a = 1
        }
        func two() {
            let b = 2
        }
        let tail = 3
        """
        let store = NSTextStorage(string: src)
        let ns = store.string as NSString
        // Fold the SECOND block first so the first block's offsets stay valid.
        let second = try XCTUnwrap(fm.foldableRange(onLine: 4, displayText: ns))
        fm.fold(range: second, in: store)
        let first = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))
        fm.fold(range: first, in: store)
        XCTAssertEqual(fm.regions.count, 2)

        let pasted = "// header\n// header\n// header\n"
        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: pasted)

        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, pasted + src)
    }

    func testDeletionAboveAFoldKeepsFullTextExact() throws {
        let fm = FoldingManager()
        let src = "// lead\n" + source(ending: "\n")
        let store = NSTextStorage(string: src)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 2, displayText: store.string as NSString))
        fm.fold(range: range, in: store)

        // Delete the whole first line, including its newline.
        store.replaceCharacters(in: NSRange(location: 0, length: 8), with: "")

        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, source(ending: "\n"))
    }

    func testUnfoldAfterAnEditRestoresAtTheRightPlace() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)

        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")

        let location = try XCTUnwrap(fm.regions.first?.displayLocation)
        fm.unfold(at: location, in: store)

        XCTAssertTrue(fm.regions.isEmpty)
        XCTAssertEqual(store.string, "X" + src)
        assertNoPlaceholder(store.string)
    }

    func testAnEditThatDeletesThePlaceholderDropsTheRegion() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)

        // Select from the top through the placeholder and past it, and delete.
        let placeholder = try XCTUnwrap(fm.regions.first?.displayLocation)
        store.replaceCharacters(in: NSRange(location: 0, length: placeholder + 1), with: "")

        XCTAssertTrue(fm.regions.isEmpty, "the placeholder is gone; the region describes nothing")
        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, store.string)
    }

    func testDeletionStraddlingThePlaceholderDropsTheRegion() throws {
        let fm = FoldingManager()
        let src = "// lead\n" + source(ending: "\n")
        let store = NSTextStorage(string: src)
        let range = try XCTUnwrap(fm.foldableRange(onLine: 2, displayText: store.string as NSString))
        fm.fold(range: range, in: store)
        let placeholder = try XCTUnwrap(fm.regions.first?.displayLocation)

        // A range that starts before the placeholder and ends after it.
        store.replaceCharacters(in: NSRange(location: placeholder - 2, length: 4), with: "Z")

        XCTAssertTrue(fm.regions.isEmpty)
        assertNoPlaceholder(fm.fullText(from: store))
    }

    /// A same-length overwrite of the placeholder character. `changeInLength`
    /// is 0, so a fix that only reacts to length changes still leaves a region
    /// pointing at a character that is no longer an attachment.
    func testSameLengthOverwriteOfThePlaceholderDropsTheRegion() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)
        let placeholder = try XCTUnwrap(fm.regions.first?.displayLocation)

        store.replaceCharacters(in: NSRange(location: placeholder, length: 1), with: "Z")

        XCTAssertTrue(fm.regions.isEmpty)
        assertNoPlaceholder(fm.fullText(from: store))
        XCTAssertEqual(fm.fullText(from: store), store.string)
    }

    func testEditBelowAFoldLeavesTheRegionAlone() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)
        let before = try XCTUnwrap(fm.regions.first?.displayLocation)

        store.replaceCharacters(in: NSRange(location: store.length, length: 0), with: "more\n")

        XCTAssertEqual(fm.regions.first?.displayLocation, before)
        XCTAssertEqual(fm.fullText(from: store), src + "more\n")
    }

    /// Edits inside a `beginEditing`/`endEditing` group arrive coalesced as one
    /// notification whose range covers every sub-edit.
    func testCoalescedEditGroupIsHandled() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)

        store.beginEditing()
        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "AB")
        store.replaceCharacters(in: NSRange(location: 1, length: 1), with: "")
        store.endEditing()

        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, "A" + src)
    }

    /// Folding and unfolding do their own shifting; the edit observer must not
    /// double-count them.
    func testFoldAndUnfoldStillRoundTrip() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)
        let loc = try XCTUnwrap(fm.regions.first?.displayLocation)
        fm.unfold(at: loc, in: store)
        XCTAssertEqual(store.string, src)
        XCTAssertEqual(fm.fullText(from: store), src)
    }

    func testTwoFoldsThenAnEditBetweenThemShiftsOnlyTheSecond() throws {
        let fm = FoldingManager()
        let src = """
        func one() {
            let a = 1
        }
        // middle
        func two() {
            let b = 2
        }
        """
        let store = NSTextStorage(string: src)
        let second = try XCTUnwrap(fm.foldableRange(onLine: 5, displayText: store.string as NSString))
        fm.fold(range: second, in: store)
        let first = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: store.string as NSString))
        fm.fold(range: first, in: store)

        let firstLoc = try XCTUnwrap(fm.regions.first?.displayLocation)
        let secondLoc = try XCTUnwrap(fm.regions.last?.displayLocation)
        // Insert into the "// middle" line, which lies between the two placeholders.
        let middle = (store.string as NSString).range(of: "// middle")
        store.replaceCharacters(in: NSRange(location: middle.location, length: 0), with: "!!")

        XCTAssertEqual(fm.regions.first?.displayLocation, firstLoc)
        XCTAssertEqual(fm.regions.last?.displayLocation, secondLoc + 2)
        let rebuilt = fm.fullText(from: store)
        assertNoPlaceholder(rebuilt)
        XCTAssertEqual(rebuilt, src.replacingOccurrences(of: "// middle", with: "!!// middle"))
    }

    /// The observer must not keep the manager (or the storage) alive, and must
    /// stop firing once every fold is gone.
    func testObserverIsReleasedWhenNoRegionsRemain() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)
        fm.unfoldAll(in: store)
        XCTAssertTrue(fm.regions.isEmpty)

        // No regions, so this must be a no-op rather than a crash or a resurrection.
        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertTrue(fm.regions.isEmpty)
        XCTAssertEqual(fm.fullText(from: store), "X" + src)
    }

    func testDiscardRegionsStopsTracking() throws {
        let fm = FoldingManager()
        let src = source(ending: "\n")
        let store = NSTextStorage(string: src)
        try foldFirstBlock(fm, store)
        fm.discardRegions()
        store.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertTrue(fm.regions.isEmpty)
    }
}

// MARK: - T5 / T7: TextLineIndex

@MainActor
final class TextLineIndexBreakSetTests: XCTestCase {

    /// The gutter numbers rows with `NSString.lineRange`; `TextLineIndex` must
    /// agree with it or the numbers drawn disagree with the rows they label.
    private func nsStringLine(in s: NSString, at loc: Int) -> Int {
        var line = 1
        var i = 0
        while i < loc {
            var start = 0, end = 0, contentsEnd = 0
            s.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                           for: NSRange(location: i, length: 0))
            // `loc` sits inside this line, or inside the break that ends it.
            if end > loc { break }
            // No break at the end of this line — it is the last one.
            if contentsEnd == end { break }
            i = end
            line += 1
        }
        return line
    }

    private func assertAgreesWithNSString(_ text: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let ns = text as NSString
        for loc in 0...ns.length {
            XCTAssertEqual(TextLineIndex.lineNumber(in: ns, at: loc),
                           nsStringLine(in: ns, at: loc),
                           "disagreement at offset \(loc) of \(text.debugDescription)",
                           file: file, line: line)
        }
    }

    func testCarriageReturnStartsANewLine() {
        assertAgreesWithNSString("a\rb")
        XCTAssertEqual(TextLineIndex.lineNumber(in: "a\rb" as NSString, at: 2), 2)
    }

    func testLineSeparatorStartsANewLine() {
        assertAgreesWithNSString("a\u{2028}b")
        XCTAssertEqual(TextLineIndex.lineNumber(in: "a\u{2028}b" as NSString, at: 2), 2)
    }

    func testParagraphSeparatorStartsANewLine() {
        assertAgreesWithNSString("a\u{2029}b")
    }

    func testNextLineStartsANewLine() {
        assertAgreesWithNSString("a\u{0085}b")
        XCTAssertEqual(TextLineIndex.lineNumber(in: "a\u{0085}b" as NSString, at: 2), 2)
    }

    func testCRLFIsASingleBreak() {
        let ns = "a\r\nb" as NSString
        XCTAssertEqual(TextLineIndex.lineNumber(in: ns, at: ns.length), 2)
        assertAgreesWithNSString("a\r\nb")
    }

    func testVerticalTabAndFormFeedAreNotLineBreaks() {
        // NSString.lineRange does not break on these, so neither may we.
        assertAgreesWithNSString("a\u{000B}b")
        assertAgreesWithNSString("a\u{000C}b")
    }

    func testMixedSampleAgreesWithNSStringEverywhere() {
        assertAgreesWithNSString("one\ntwo\r\nthree\rfour\u{2028}five\u{2029}six\u{0085}seven\n")
    }

    func testLFAndCRLFResultsAreUnchanged() {
        XCTAssertEqual(TextLineIndex.lineNumber(in: "a\nb\nc" as NSString, at: 4), 3)
        let (line, start) = TextLineIndex.lineAndStart(in: "a\nbb\nc" as NSString, at: 5)
        XCTAssertEqual(line, 3)
        XCTAssertEqual(start, 5)
    }

    func testLineStartMatchesLineNumberForEveryBreakKind() {
        let text = "one\ntwo\r\nthree\rfour\u{2028}five\u{2029}six\u{0085}seven" as NSString
        for wanted in 1...7 {
            let start = TextLineIndex.lineStart(of: wanted, in: text)
            XCTAssertEqual(TextLineIndex.lineNumber(in: text, at: start), wanted,
                           "lineStart(of: \(wanted)) = \(start) does not report back as line \(wanted)")
        }
    }

    func testLineNumbersBatchAgreesWithTheSingleLookup() {
        let text = "one\ntwo\r\nthree\rfour\u{2028}five\u{2029}six\u{0085}seven\n" as NSString
        let offsets = Array(0...text.length)
        let batch = TextLineIndex.lineNumbers(in: text, at: offsets)
        for (i, offset) in offsets.enumerated() {
            XCTAssertEqual(batch[i], TextLineIndex.lineNumber(in: text, at: offset),
                           "batch disagrees with the single lookup at \(offset)")
        }
    }
}

@MainActor
final class TextLineIndexCursorTests: XCTestCase {

    private let sample = "alpha\nbeta\r\ngamma\rdelta\u{2028}epsilon\u{2029}zeta\u{0085}eta\nomega" as NSString

    func testCursorMatchesTheColdLookupWalkingForwards() {
        var cursor = TextLineIndex.Cursor()
        for loc in 0...sample.length {
            let cached = cursor.lineAndStart(in: sample, at: loc, stamp: 1)
            let cold = TextLineIndex.lineAndStart(in: sample, at: loc)
            XCTAssertEqual(cached.line, cold.line, "forward walk disagrees at \(loc)")
            XCTAssertEqual(cached.lineStart, cold.lineStart, "forward walk lineStart disagrees at \(loc)")
        }
    }

    func testCursorMatchesTheColdLookupWalkingBackwards() {
        var cursor = TextLineIndex.Cursor()
        for loc in stride(from: sample.length, through: 0, by: -1) {
            let cached = cursor.lineAndStart(in: sample, at: loc, stamp: 1)
            let cold = TextLineIndex.lineAndStart(in: sample, at: loc)
            XCTAssertEqual(cached.line, cold.line, "backward walk disagrees at \(loc)")
            XCTAssertEqual(cached.lineStart, cold.lineStart, "backward walk lineStart disagrees at \(loc)")
        }
    }

    func testCursorMatchesTheColdLookupJumpingAround() {
        var cursor = TextLineIndex.Cursor()
        var seed: UInt64 = 0x5EED
        for _ in 0..<400 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let loc = Int(seed >> 33) % (sample.length + 1)
            let cached = cursor.lineAndStart(in: sample, at: loc, stamp: 1)
            let cold = TextLineIndex.lineAndStart(in: sample, at: loc)
            XCTAssertEqual(cached.line, cold.line, "random jump disagrees at \(loc)")
            XCTAssertEqual(cached.lineStart, cold.lineStart, "random jump lineStart disagrees at \(loc)")
        }
    }

    /// A stale cursor over edited text is the way this optimisation turns into a
    /// correctness bug, so a changed stamp must throw the memo away.
    func testChangingTheStampResetsTheCursor() {
        var cursor = TextLineIndex.Cursor()
        let before = "one\ntwo\nthree" as NSString
        _ = cursor.lineAndStart(in: before, at: before.length, stamp: 1)

        let after = "one\ntwo\nthree\nfour\nfive" as NSString
        let fresh = cursor.lineAndStart(in: after, at: after.length, stamp: 2)
        XCTAssertEqual(fresh.line, TextLineIndex.lineAndStart(in: after, at: after.length).line)
    }

    func testCursorOnALargeStringWalksTheDeltaOnly() {
        // Correctness on a big buffer, where a cold scan and a delta scan are
        // most likely to diverge on chunk boundaries.
        let text = String(repeating: "0123456789abcde\n", count: 60_000) as NSString
        var cursor = TextLineIndex.Cursor()
        for step in 0..<50 {
            let loc = text.length - 4000 + step * 7
            let cached = cursor.lineAndStart(in: text, at: loc, stamp: 9)
            let cold = TextLineIndex.lineAndStart(in: text, at: loc)
            XCTAssertEqual(cached.line, cold.line)
            XCTAssertEqual(cached.lineStart, cold.lineStart)
        }
    }
}

// MARK: - T2: find bar must not act on stale ranges

final class FindMatchingVerificationTests: XCTestCase {

    private func regex(_ pattern: String, useRegex: Bool = false,
                       wholeWord: Bool = false, caseSensitive: Bool = false) throws -> NSRegularExpression {
        try FindMatching.regex(pattern: pattern, useRegex: useRegex,
                               wholeWord: wholeWord, caseSensitive: caseSensitive)
    }

    func testRangesThatStillMatchAreKept() throws {
        let text = "alpha beta alpha" as NSString
        let re = try regex("alpha")
        let ranges = FindMatching.matches(in: text as String, regex: re, limit: 100).ranges
        XCTAssertEqual(FindMatching.stillMatching(ranges, in: text, regex: re), ranges)
    }

    /// The shipped bug: the user typed after the find bar computed its matches,
    /// so the ranges point at text that is no longer the query. Replacing
    /// through them overwrites innocent characters.
    func testRangesOverStaleTextAreDropped() throws {
        let original = "alpha beta alpha" as NSString
        let re = try regex("alpha")
        let ranges = FindMatching.matches(in: original as String, regex: re, limit: 100).ranges
        XCTAssertEqual(ranges.count, 2)

        // The document changed underneath: two characters inserted at the top.
        let edited = "XXalpha beta alpha" as NSString
        let survivors = FindMatching.stillMatching(ranges, in: edited, regex: re)
        XCTAssertTrue(survivors.isEmpty,
                      "both ranges now straddle other text; replacing through them corrupts the document")
    }

    func testRangesPastTheEndOfTheTextAreDropped() throws {
        let re = try regex("alpha")
        let ranges = [NSRange(location: 0, length: 5), NSRange(location: 40, length: 5)]
        let survivors = FindMatching.stillMatching(ranges, in: "alpha" as NSString, regex: re)
        XCTAssertEqual(survivors, [NSRange(location: 0, length: 5)])
    }

    func testAPartialOverlapIsNotAccepted() throws {
        let re = try regex("alpha")
        // "alphabet": a 5-unit range at 0 still reads "alpha", which IS a match.
        XCTAssertEqual(FindMatching.stillMatching([NSRange(location: 0, length: 5)],
                                                  in: "alphabet" as NSString, regex: re),
                       [NSRange(location: 0, length: 5)])
        // A 6-unit range is not a match of the query, so it must not be replaced.
        XCTAssertTrue(FindMatching.stillMatching([NSRange(location: 0, length: 6)],
                                                 in: "alphabet" as NSString, regex: re).isEmpty)
    }

    func testWholeWordAndCaseOptionsSurviveTheRoundTrip() throws {
        let text = "Alpha alphabet alpha" as NSString
        let re = try regex("alpha", wholeWord: true, caseSensitive: true)
        let ranges = FindMatching.matches(in: text as String, regex: re, limit: 100).ranges
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(text.substring(with: ranges[0]), "alpha")
        XCTAssertEqual(FindMatching.stillMatching(ranges, in: text, regex: re), ranges)
    }

    func testRegexRangesAreVerifiedAgainstThePatternNotTheLiteralText() throws {
        let re = try regex(#"\d+"#, useRegex: true)
        let ranges = FindMatching.matches(in: "a 123 b", regex: re, limit: 100).ranges
        XCTAssertEqual(ranges, [NSRange(location: 2, length: 3)])
        // Same offsets, different content: no longer digits.
        XCTAssertTrue(FindMatching.stillMatching(ranges, in: "a xyz b" as NSString, regex: re).isEmpty)
    }

    func testMatchLimitTruncates() throws {
        let re = try regex("a")
        let result = FindMatching.matches(in: String(repeating: "a", count: 50), regex: re, limit: 10)
        XCTAssertEqual(result.ranges.count, 10)
        XCTAssertTrue(result.truncated)
    }
}

// MARK: - T6 / T8: the gutter

@MainActor
final class GutterDocumentIdentityTests: XCTestCase {

    /// A gutter wired to a text view, with no window. Everything asserted here
    /// is state, not drawing, so nothing needs to be on screen.
    private func makeGutter(text: String) -> (LineNumberRulerView, NSTextView, NSTextStorage) {
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.documentView = textView
        return (LineNumberRulerView(scrollView: scroll, textView: textView), textView, storage)
    }

    /// The gutter widened for a 12,000-line file and never came back down, so
    /// every other tab in the window kept a five-digit gutter.
    func testGutterWidthResetsWhenTheDocumentChanges() {
        let (gutter, _, _) = makeGutter(text: "one\ntwo\nthree\n")
        let firstDocument = UUID()
        let secondDocument = UUID()

        gutter.syncDocumentIdentity(firstDocument)
        gutter.widestNumberSeen = 12_000
        let wideWidth = gutter.preferredWidth()

        gutter.syncDocumentIdentity(secondDocument)
        XCTAssertEqual(gutter.widestNumberSeen, 0, "the high-water mark belongs to one document")
        XCTAssertLessThan(gutter.preferredWidth(), wideWidth)
        XCTAssertEqual(gutter.preferredWidth(), LineNumberRulerView.gutterWidth,
                       "and it should be back to the two-digit base width")
    }

    func testTheSameDocumentKeepsItsHighWaterMark() {
        let (gutter, _, _) = makeGutter(text: "one\ntwo\n")
        let document = UUID()
        gutter.syncDocumentIdentity(document)
        gutter.widestNumberSeen = 12_000
        let wide = gutter.preferredWidth()
        gutter.syncDocumentIdentity(document)
        XCTAssertEqual(gutter.preferredWidth(), wide, "scrolling must not shrink the gutter")
    }

    func testFoldLineSpansReportsOneEntryPerCollapsedFold() throws {
        let src = """
        func one() {
            let a = 1
            let b = 2
        }
        // middle
        func two() {
            let c = 3
        }
        tail
        """
        let (gutter, _, storage) = makeGutter(text: src)
        let fm = FoldingManager()
        gutter.foldingManager = fm

        let second = try XCTUnwrap(fm.foldableRange(onLine: 6, displayText: storage.string as NSString))
        fm.fold(range: second, in: storage)
        let first = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: storage.string as NSString))
        fm.fold(range: first, in: storage)

        let document = UUID()
        let spans = gutter.foldLineSpans(displayText: storage.string as NSString, documentID: document)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.map(\.displayLine), [1, 3], "display rows, after the earlier fold collapsed")
        XCTAssertEqual(spans.map(\.hidden), [3, 2])

        // Second call comes from the cache and must agree with the first.
        let again = gutter.foldLineSpans(displayText: storage.string as NSString, documentID: document)
        XCTAssertEqual(again.map(\.displayLine), spans.map(\.displayLine))
        XCTAssertEqual(again.map(\.hidden), spans.map(\.hidden))
    }

    func testFoldLineSpansCacheIsDroppedWhenTheDocumentChanges() throws {
        let src = "func one() {\n    let a = 1\n}\ntail"
        let (gutter, _, storage) = makeGutter(text: src)
        let fm = FoldingManager()
        gutter.foldingManager = fm
        let range = try XCTUnwrap(fm.foldableRange(onLine: 1, displayText: storage.string as NSString))
        fm.fold(range: range, in: storage)

        let a = UUID()
        _ = gutter.foldLineSpans(displayText: storage.string as NSString, documentID: a)
        gutter.syncDocumentIdentity(a)
        gutter.syncDocumentIdentity(UUID())

        fm.discardRegions()
        XCTAssertTrue(gutter.foldLineSpans(displayText: storage.string as NSString, documentID: UUID()).isEmpty)
    }
}

// MARK: - Perf evidence for the fixes that needed new API
//
// `PerfHarnessFoldingTests` has to compile on the pre-fix commit, so it can only
// measure the shape the fix REMOVES. This is its replacement. Read it against
// the matching pre-fix name:
//
//   textlineindex_sequential_1000_lookups_128KB → textlineindex_cursor_1000_lookups_128KB
//
// Not named PerfHarness…Tests on purpose: this class does not exist on the
// pre-fix commit and must not join the orchestrator's paired run.

@MainActor
final class FoldingAuditPerfEvidenceTests: XCTestCase {

    func testPerfTextLineIndexCursorLookups() {
        let text = PerfHarnessFoldingTests.smallSource
        let base = text.length - 2000
        PerfHarness.measure("textlineindex_cursor_1000_lookups_128KB", samples: 3, iterations: 1) {
            var cursor = TextLineIndex.Cursor()
            var checksum = 0
            for step in 0..<1000 {
                checksum &+= cursor.lineAndStart(in: text, at: base + step, stamp: 1).line
            }
            return checksum
        }
    }

    /// One gutter frame with nothing changed — the scroll case, where the span
    /// map now comes back from the cache instead of being recomputed.
    func testPerfGutterFoldLineSpansCached() throws {
        let storage = NSTextStorage(string: PerfHarnessFoldingTests.foldableSource())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  textContainer: container)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.documentView = textView
        let gutter = LineNumberRulerView(scrollView: scroll, textView: textView)

        let fm = FoldingManager()
        gutter.foldingManager = fm
        for range in fm.foldableRanges(in: storage.string as NSString).reversed() {
            fm.fold(range: range, in: storage)
        }
        XCTAssertEqual(fm.regions.count, 40)

        let documentID = UUID()
        PerfHarness.measure("gutter_foldLineSpans_40_folds_cached", samples: 5, iterations: 1) {
            gutter.foldLineSpans(displayText: storage.string as NSString, documentID: documentID)
                .reduce(0) { $0 &+ $1.displayLine }
        }
    }
}
