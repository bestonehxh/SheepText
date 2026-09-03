import AppKit
import XCTest
@testable import SheepText

/// Regression cover for the compare **display layer** findings of the September
/// 2026 audit (`EditorView.swift` + `EditorTextView.realText`):
///
/// * **C1** — the header counted its diff in a second, index-aligned build mode
///   the panes were not using, so a 600-line compare said "400 changed" over
///   panes showing "1 added / 1 removed". That mode is gone.
/// * **C3** — `detectMovedRows` lifted a row out of its position, which made
///   `realLineNumber` non-monotonic inside a diff block and turned a block
///   transfer into a duplicate or a silent no-op.
/// * **C4** — a keystroke landing while a rebuild was in flight was overwritten
///   by that rebuild's stale snapshot.
/// * **C5 / P2** — every layer re-derived line boundaries with
///   `NSString.paragraphRange`, which breaks on a lone CR and U+2029 while
///   `LineHashing.splitLines` does not, so a real line was marked filler and
///   dropped out of the document.
/// * **C6** — blank and boilerplate lines were matched as "moved" across the
///   whole file.
/// * **C8** — a word highlight reaching the end of a CRLF line painted over the CR.
/// * **P1** — the word-level diff ran once per pane, allocated a String per
///   token, and treated every Thai/CJK character as its own token.
@MainActor
final class EditorCompareAuditFixTests: XCTestCase {

    // MARK: - Helpers

    private func lines(_ count: Int, prefix: String = "interface GigabitEthernet1/0/") -> [String] {
        (0..<count).map { "\(prefix)\($0)" }
    }

    /// Builds one pane's display and materialises it into a storage exactly as
    /// `applyCompareDisplay` does: the text, plus `.isFillerLine` over each
    /// filler row's full range.
    private func storage(left: String, right: String, leftSide: Bool) -> (NSTextStorage, CompareBenchmarkSeam.DisplayProbe) {
        let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: leftSide)
        let storage = NSTextStorage(string: probe.displayText)
        for range in probe.fillerRanges {
            storage.addAttribute(.isFillerLine, value: true, range: range)
        }
        return (storage, probe)
    }

    private func editor() -> EditorTextView {
        EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    }

    // MARK: - C5 / P2: row ranges, not paragraphs

    /// The headline data-loss case. `"a\rb"` is ONE line to
    /// `LineHashing.splitLines` (Swift sees `\r` as an ordinary character, and
    /// the splitter only breaks on LF) but TWO paragraphs to
    /// `NSString.paragraphRange`. Pairing paragraphs with rows one for one put
    /// the filler attribute on the row above, so `realText(from:)` — which is
    /// what becomes `document.text`, and what gets saved — dropped a real line.
    func testLoneCRDisplayRoundTripsThroughRealText() {
        let left  = "a\rb\nc"
        let right = "a\rb\nc\nextra"
        let (store, probe) = storage(left: left, right: right, leftSide: true)

        XCTAssertEqual(probe.rows.count, 3, "three rows: the CR does not split a line")
        XCTAssertEqual(probe.rows.map(\.text), ["a\rb", "c", ""])
        XCTAssertEqual(probe.fillerRanges.count, 1)

        XCTAssertEqual(editor().realText(from: store), left,
                       "the left document must survive the round trip unchanged")
    }

    /// U+2029 PARAGRAPH SEPARATOR is the other character paragraphRange breaks
    /// on and the compare pipeline does not.
    func testParagraphSeparatorDisplayRoundTripsThroughRealText() {
        let left  = "alpha\u{2029}beta\ngamma"
        let right = "alpha\u{2029}beta\ngamma\ndelta"
        let (store, probe) = storage(left: left, right: right, leftSide: true)

        XCTAssertEqual(probe.rows.count, 3)
        XCTAssertEqual(editor().realText(from: store), left)
    }

    /// The ordinary shapes must be byte-identical to what they always were.
    func testPlainAndCRLFDisplaysStillRoundTrip() {
        for (left, right) in [
            ("one\ntwo\nthree", "one\ntwo\nthree\nfour"),
            ("one\r\ntwo\r\nthree", "one\r\ntwo\r\nthree\r\nfour"),
            ("only", "only\nplus"),
            ("", "added")
        ] {
            for leftSide in [true, false] {
                let (store, _) = storage(left: left, right: right, leftSide: leftSide)
                XCTAssertEqual(editor().realText(from: store), leftSide ? left : right,
                               "round trip failed for \(leftSide ? "left" : "right") of \(left.debugDescription)")
            }
        }
    }

    /// Every filler row must be marked, and only filler rows.
    func testFillerRunCountEqualsFillerRowCount() {
        let left = lines(20).joined(separator: "\n")
        var rightLines = lines(20)
        rightLines.insert(contentsOf: ["vlan 10", "vlan 20", "vlan 30"], at: 8)
        let (store, probe) = storage(left: left, right: rightLines.joined(separator: "\n"), leftSide: true)

        var marked: [NSRange] = []
        store.enumerateAttribute(.isFillerLine, in: NSRange(location: 0, length: store.length)) { value, range, _ in
            if value != nil { marked.append(range) }
        }
        XCTAssertEqual(marked.count, 1, "the three filler rows are contiguous, so one run")
        XCTAssertEqual(probe.fillerRanges.count, 3)
        XCTAssertEqual(marked.first?.length, probe.fillerRanges.reduce(0) { $0 + $1.length })
    }

    /// Row ranges must tile the display text exactly: no gaps, no overlaps, and
    /// they must end where the text does.
    func testRowRangesTileTheDisplayTextExactly() {
        let left = lines(50).joined(separator: "\r\n")
        var rightLines = lines(50)
        rightLines[10] += " changed"
        rightLines.remove(at: 30)
        let probe = CompareBenchmarkSeam.displayProbe(
            left: left, right: rightLines.joined(separator: "\n"), leftSide: true)

        var expected = 0
        for row in probe.rows {
            XCTAssertEqual(row.range.location, expected)
            XCTAssertLessThanOrEqual(row.contentEnd, NSMaxRange(row.range))
            expected = NSMaxRange(row.range)
        }
        XCTAssertEqual(expected, (probe.displayText as NSString).length)
    }

    // MARK: - C8: the highlight clamp knows its own separator

    /// On a CRLF document the row's raw text still carries the `\r`, so a word
    /// highlight running to the end of the line used to paint one cell past the
    /// last glyph, over the CR.
    func testWordHighlightsNeverReachIntoTheLineSeparator() {
        let left  = "interface Gi1/0/1 description alpha\r\ntail"
        let right = "interface Gi1/0/1 description omega\r\ntail"
        for leftSide in [true, false] {
            let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: leftSide)
            let changed = probe.rows[0]
            XCTAssertEqual(changed.kind, "c")
            XCTAssertFalse(changed.wordHighlights.isEmpty, "the changed word must be highlighted")
            for highlight in changed.wordHighlights {
                XCTAssertLessThanOrEqual(NSMaxRange(highlight), changed.contentEnd,
                                         "highlight ran into the CRLF separator")
            }
        }
    }

    // MARK: - P1: one op stream, both panes, Thai as words

    /// The two panes' highlights are the two halves of one diff: the left pane
    /// marks what only the left line has, the right pane what only the right has.
    func testWordHighlightsAreTheTwoHalvesOfOneDiff() {
        let left  = "vlan 100 name alpha"
        let right = "vlan 100 name omega"
        let leftProbe  = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: true)
        let rightProbe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: false)

        XCTAssertEqual(leftProbe.rows[0].wordHighlights.count, 1)
        XCTAssertEqual(rightProbe.rows[0].wordHighlights.count, 1)
        XCTAssertEqual((left as NSString).substring(with: leftProbe.rows[0].wordHighlights[0]), "alpha")
        XCTAssertEqual((right as NSString).substring(with: rightProbe.rows[0].wordHighlights[0]), "omega")
    }

    /// `isWordChar` was ASCII only, so every Thai character was its own token
    /// and the highlight came back as per-character confetti. A Thai word is one
    /// token now, so the changed word is one span.
    func testThaiWordsAreOneTokenNotOnePerCharacter() {
        let left  = "อินเทอร์เฟซ 100 คำอธิบาย ผู้ใช้"
        let right = "อินเทอร์เฟซ 100 คำอธิบาย ผู้ดูแล"
        let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: true)

        XCTAssertEqual(probe.rows[0].kind, "c")
        XCTAssertEqual(probe.rows[0].wordHighlights.count, 1,
                       "one changed word means one span, not one per character")
        XCTAssertEqual((left as NSString).substring(with: probe.rows[0].wordHighlights[0]), "ผู้ใช้")
    }

    /// Identical lines get no highlights at all, on either side.
    func testUnchangedRowsCarryNoWordHighlights() {
        let left  = "keep me\nvlan 100"
        let right = "keep me\nvlan 200"
        for leftSide in [true, false] {
            let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: leftSide)
            XCTAssertTrue(probe.rows[0].wordHighlights.isEmpty)
            XCTAssertFalse(probe.rows[1].wordHighlights.isEmpty)
        }
    }

    // MARK: - C6: what counts as a move

    /// Deleting a blank line at the top and adding one at the bottom is not a
    /// move. It used to be reported as one — and the added row was yanked out of
    /// position, so the right pane's gutter read 9, 1, 2, 3, 4, 5, 6, 7, 8.
    func testBlankLineAtTopAndBottomIsNotAMove() {
        let body = (1...8).map { "line \($0)" }
        let left  = ([""] + body).joined(separator: "\n")
        let right = (body + [""]).joined(separator: "\n")

        let kinds = CompareBenchmarkSeam.rowKinds(left: left, right: right)
        XCTAssertFalse(kinds.contains("m"), "kinds were \(kinds)")
        XCTAssertTrue(kinds.contains("l") || kinds.contains("p"))
        XCTAssertTrue(kinds.contains("r") || kinds.contains("p"))
    }

    /// The same for the boilerplate a Cisco config is made of.
    func testShortBoilerplateLinesAreNeverMoved() {
        for filler in ["!", "exit", "}", " "] {
            let body = (1...6).map { "interface GigabitEthernet1/0/\($0)" }
            let left  = ([filler] + body).joined(separator: "\n")
            let right = (body + [filler]).joined(separator: "\n")
            XCTAssertFalse(CompareBenchmarkSeam.rowKinds(left: left, right: right).contains("m"),
                           "\(filler.debugDescription) was treated as a moved line")
        }
    }

    /// A real move still has to be found: five substantial lines relocated 300
    /// rows down the file.
    func testGenuineBlockMoveAcrossThreeHundredRowsIsStillDetected() {
        var leftLines = lines(400)
        let block = (0..<5).map { "ip access-list extended MOVED-BLOCK-RULE-\($0)" }
        leftLines.insert(contentsOf: block, at: 20)
        var rightLines = lines(400)
        rightLines.insert(contentsOf: block, at: 320)

        let probe = CompareBenchmarkSeam.displayProbe(
            left: leftLines.joined(separator: "\n"),
            right: rightLines.joined(separator: "\n"),
            leftSide: true)
        let moved = probe.rows.filter { $0.kind == "m" }
        XCTAssertEqual(moved.count, 10, "five rows on each side, annotated in place")
        XCTAssertEqual(moved.filter { !$0.isFiller }.count, 5, "five of them live on the left pane")
        for row in moved where !row.isFiller {
            XCTAssertNotNil(row.mappedLineNumber, "a moved row must name its counterpart")
        }
    }

    // MARK: - C3: block transfer arithmetic

    /// Reversed lines: with the old row-reordering the right pane's real line
    /// numbers came back 3, 2, 1, 4, so a transfer of the first two rows
    /// computed `replaceStart = 2, replaceCount = 0` — an INSERT, duplicating
    /// the block — or, with three reversed lines, a negative count that silently
    /// did nothing. Now the rows keep their positions, so the range covers
    /// exactly the block; a shape that still is not a contiguous run is refused.
    func testReversedLinesTransferCoversTheBlockOrIsRefused() {
        let left  = "X\nY\nZ\ncommon"
        let right = "Z\nY\nX\ncommon"

        for leftSide in [true, false] {
            let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: leftSide)
            let real = probe.rows.compactMap(\.realLineNumber)
            XCTAssertEqual(real, real.sorted(), "real line numbers must stay in order: \(real)")

            let rows = NSRange(location: 0, length: 2)
            let range = CompareBenchmarkSeam.transferReplaceRange(
                left: left, right: right, leftSide: leftSide, displayRows: rows)
            if let range {
                let covered = probe.rows[0..<2].compactMap(\.realLineNumber)
                XCTAssertEqual(range.start, (covered.first ?? 1) - 1)
                XCTAssertEqual(range.count, covered.count)
            }
        }
    }

    /// A block whose real lines are not contiguous — a filler for the peer's
    /// moved row sitting between two deleted lines — must be refused, not
    /// silently expanded to swallow everything between them.
    func testNonContiguousBlockIsRefused() {
        let infos = [
            CompareLineInfo(realLineNumber: 2, isFiller: false, gutterSymbol: "−",
                            style: .removed, mappedLineNumber: nil, charHighlights: []),
            CompareLineInfo(realLineNumber: 100, isFiller: false, gutterSymbol: "−",
                            style: .removed, mappedLineNumber: nil, charHighlights: [])
        ]
        XCTAssertNil(CompareTransferGeometry.replaceRange(
            infos: infos, displayRows: NSRange(location: 0, length: 2)))

        let descending = [
            CompareLineInfo(realLineNumber: 3, isFiller: false, gutterSymbol: "+",
                            style: .added, mappedLineNumber: nil, charHighlights: []),
            CompareLineInfo(realLineNumber: 2, isFiller: false, gutterSymbol: "+",
                            style: .added, mappedLineNumber: nil, charHighlights: [])
        ]
        XCTAssertNil(CompareTransferGeometry.replaceRange(
            infos: descending, displayRows: NSRange(location: 0, length: 2)))
    }

    /// The ordinary shapes still compute what they always did.
    func testOrdinaryBlocksStillComputeTheSameReplaceRange() {
        let contiguous = (4...6).map {
            CompareLineInfo(realLineNumber: $0, isFiller: false, gutterSymbol: "−",
                            style: .removed, mappedLineNumber: nil, charHighlights: [])
        }
        let range = CompareTransferGeometry.replaceRange(
            infos: contiguous, displayRows: NSRange(location: 0, length: 3))
        XCTAssertEqual(range?.start, 3)
        XCTAssertEqual(range?.count, 3)

        // All filler: a pure insertion after the nearest real line above.
        let withFiller = [
            CompareLineInfo(realLineNumber: 7, isFiller: false, gutterSymbol: "",
                            style: .same, mappedLineNumber: nil, charHighlights: []),
            CompareLineInfo(realLineNumber: nil, isFiller: true, gutterSymbol: "",
                            style: .filler, mappedLineNumber: nil, charHighlights: [])
        ]
        let insertion = CompareTransferGeometry.replaceRange(
            infos: withFiller, displayRows: NSRange(location: 1, length: 1))
        XCTAssertEqual(insertion?.start, 7)
        XCTAssertEqual(insertion?.count, 0)
    }

    /// A real one-block transfer, end to end through `CompareBlockSplice`: the
    /// computed range must replace exactly the block the user clicked.
    func testTransferOfAChangedBlockReplacesExactlyThatBlock() {
        var leftLines = lines(30)
        leftLines[12] = "vlan 100 name alpha"
        var rightLines = lines(30)
        rightLines[12] = "vlan 200 name beta"
        let left = leftLines.joined(separator: "\n")
        let right = rightLines.joined(separator: "\n")

        let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: false)
        guard let row = probe.rows.firstIndex(where: { $0.gutterSymbol != "" || $0.isFiller }) else {
            return XCTFail("no diff row")
        }
        guard let range = CompareBenchmarkSeam.transferReplaceRange(
            left: left, right: right, leftSide: false, displayRows: NSRange(location: row, length: 1))
        else { return XCTFail("transfer refused") }

        let spliced = CompareBlockSplice.apply(
            text: right, replaceStart: range.start, replaceCount: range.count,
            replacementLines: ["vlan 100 name alpha"], lineEnding: .lf)
        XCTAssertEqual(spliced, left)
    }

    /// A moved block is the shape that used to produce the broken arithmetic.
    /// Its rows now stay in place, so the block's real line numbers are one
    /// contiguous run on the side that owns them, and the peer's aligned rows
    /// are all filler — a pure insertion, exactly like an added block.
    func testMovedBlockTransfersAsAContiguousRun() {
        let block = (0..<5).map { "ip access-list extended MOVED-BLOCK-RULE-\($0)" }
        var leftLines = lines(120)
        leftLines.insert(contentsOf: block, at: 20)
        var rightLines = lines(120)
        rightLines.insert(contentsOf: block, at: 90)
        let left = leftLines.joined(separator: "\n")
        let right = rightLines.joined(separator: "\n")

        let leftProbe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: true)
        guard let start = leftProbe.rows.firstIndex(where: { $0.kind == "m" && !$0.isFiller }) else {
            return XCTFail("no moved row on the left pane")
        }
        let rows = NSRange(location: start, length: 5)
        guard let owned = CompareBenchmarkSeam.transferReplaceRange(
            left: left, right: right, leftSide: true, displayRows: rows) else {
            return XCTFail("transfer refused on the side that owns the block")
        }
        XCTAssertEqual(owned.count, 5)
        XCTAssertEqual(owned.start, 20)

        // The same display rows on the peer are filler, so the peer computes an
        // insertion (count 0) rather than a replace.
        let peer = CompareBenchmarkSeam.transferReplaceRange(
            left: left, right: right, leftSide: false, displayRows: rows)
        XCTAssertEqual(peer?.count, 0)
    }

    // MARK: - C1: one build mode, one answer

    /// The 600-line case from the audit: one line inserted near the top and one
    /// deleted near the bottom. The header used to report ~400 changed rows over
    /// panes rendering one added and one removed.
    func testHeaderCountsAgreeWithThePaneRows() {
        var leftLines = lines(600)
        var rightLines = leftLines
        rightLines.insert("vlan 4000 name inserted-here", at: 100)
        rightLines.remove(at: 500)
        let left = leftLines.joined(separator: "\n")
        let right = rightLines.joined(separator: "\n")

        let histogram = CompareBenchmarkSeam.rowHistogram(left: left, right: right)
        let header = CompareBenchmarkSeam.headerCounts(left: left, right: right)
        // removed, added, changed, moved — .paired counts as one of each.
        XCTAssertEqual(header[0], histogram[2] + histogram[5], "removed")
        XCTAssertEqual(header[1], histogram[3] + histogram[5], "added")
        XCTAssertEqual(header[2], histogram[1], "changed")
        XCTAssertEqual(header[3] * 2, histogram[4], "moved rows come in pairs")

        XCTAssertEqual(histogram[1], 0, "nothing was changed in place")
        XCTAssertLessThanOrEqual(histogram[2] + histogram[3] + 2 * histogram[5], 4,
                                 "one insert and one delete, not four hundred")

        leftLines.removeAll()
        rightLines.removeAll()
    }

    /// The same agreement has to hold when the diff is dense enough that the old
    /// fast path would have been used for the rest of the session.
    func testHeaderCountsAgreeWithThePaneRowsOnADenseDiff() {
        let leftLines = lines(500)
        var rightLines = leftLines
        for index in stride(from: 3, to: rightLines.count, by: 7) { rightLines[index] += " changed" }
        let left = leftLines.joined(separator: "\n")
        let right = rightLines.joined(separator: "\n")

        let histogram = CompareBenchmarkSeam.rowHistogram(left: left, right: right)
        let header = CompareBenchmarkSeam.headerCounts(left: left, right: right)
        XCTAssertEqual(header[2], histogram[1])
        XCTAssertGreaterThan(histogram[1], 0)
    }

    // MARK: - C4: a rebuild that lost the race is not applied

    /// A rebuild carries a snapshot of the document taken before it was
    /// dispatched. If a keystroke landed since, that snapshot cannot contain the
    /// typed character — and writing it back deleted it from the document with
    /// no undo, because `isApplyingCompare` suppresses `textDidChange` and the
    /// apply calls `discardUndoHistory()`.
    func testStaleRebuildIsRefusedAndFreshOneIsAccepted() {
        let snapshot = "vlan 100\nvlan 200"
        let typed    = "vlan 100\nvlan 2000"   // the user added a "0"
        let peer     = "vlan 100\nvlan 999"

        let stale = CompareBenchmarkSeam.displayProbe(left: snapshot, right: peer, leftSide: true)
        XCTAssertFalse(stale.displayText.contains("vlan 2000"),
                       "a rebuild from the old snapshot cannot carry the keystroke")

        XCTAssertFalse(CompareApplyGuard.shouldApply(builtFrom: snapshot, documentText: typed))
        XCTAssertTrue(CompareApplyGuard.shouldApply(builtFrom: typed, documentText: typed))
    }

    // MARK: - Filler lines stay uneditable

    /// `shouldChangeText` refuses any edit that touches a filler line. That is
    /// the other consumer of the `.isFillerLine` attribute, and it has to keep
    /// agreeing with the rows after the range rewrite.
    func testFillerLinesRemainProtectedFromEditing() {
        let left = "one\ntwo"
        let right = "one\ntwo\nthree"
        let (store, probe) = storage(left: left, right: right, leftSide: true)
        let view = editor()
        view.layoutManager?.replaceTextStorage(store)

        guard let filler = probe.fillerRanges.first else { return XCTFail("no filler row") }
        XCTAssertFalse(view.shouldChangeText(in: filler, replacementString: "x"))
        XCTAssertTrue(view.shouldChangeText(in: NSRange(location: 0, length: 1), replacementString: "x"))
    }
}

private extension CompareBenchmarkSeam.RowProbe {
    /// End of the row's visible content — where a word highlight may reach.
    var contentEnd: Int { range.location + (text as NSString).length }
}
