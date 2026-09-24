import AppKit
import XCTest
@testable import SheepText

/// Regression cover for the compare findings of the **second** audit
/// (17 September 2026). One class per finding group; the helpers at the top are
/// shared.
///
/// * **C4** — the Myers work budget was divided by file size, so the edit
///   distance the exact search was allowed to reach shrank as the files grew:
///   40 scattered edits in a 200 000-line file fell back and reported 190 243
///   changed rows.
/// * **C3** — `CompareBlockSplice.apply` wrote a bare LF into a CRLF document
///   whenever the block was appended at the end.
/// * **C2** — a CR-only document is one row to the compare pipeline and N lines
///   to the splice, so a transfer appended the whole source file.
/// * **C1** — the incremental storage write left `.isFillerLine` stale outside
///   the replaced middle, so `realText(from:)` silently added or dropped blank
///   lines in `document.text`.
/// * **C6 / C7** — transfer arrows and finished rebuilds were live against
///   line numbers and row arrays that no longer described the documents.
/// * **C8** — the `*` edited-line markers were keyed by display row.

// MARK: - C4: the exact diff ceiling is about relatedness, not file size

final class CompareDiffCeilingTests: XCTestCase {

    private func ops(_ a: [Int], _ b: [Int]) -> [DiffOp<Int>] {
        DiffCalc.diff(a, b) { $0 == $1 }
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

    /// `count` lines, `edits` of them changed, spread evenly over the file so
    /// neither the prefix nor the suffix trim can absorb them.
    private func scattered(count: Int, edits: Int) -> ([Int], [Int]) {
        let left = Array(0..<count)
        var right = left
        let step = max(1, count / edits)
        for index in 0..<edits {
            right[min(count - 1, index * step + step / 2)] = -(index + 1)
        }
        return (left, right)
    }

    /// The headline case. `maxD = min(3000, 24_000_000 / (rn + rm))` gave
    /// `maxD = 60` here, so the exact search bailed at edit distance 60 — two
    /// edits short of the 80 this needs — and `prefixSuffixDiff` interleaved the
    /// whole trimmed middle: 190 243 rows reported as changed.
    func testFortyScatteredEditsIn200kLinesStayExact() {
        let (left, right) = scattered(count: 200_000, edits: 40)
        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
        XCTAssertEqual(counts(result).match, 199_960)
    }

    /// Two thousand scattered edits is edit distance 4000 — above the old 3000
    /// memory ceiling as well as the old work budget. It is still a file with
    /// 99 % of its lines in common and it has to diff exactly.
    func testTwoThousandScatteredEditsIn200kLinesStayExact() {
        let (left, right) = scattered(count: 200_000, edits: 2_000)
        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
        XCTAssertEqual(counts(result).match, 198_000)
    }

    /// The middle size the old budget also broke: 20 000 lines, 500 edits gave
    /// `maxD = 600` — enough by a hair for 300 edits and not for 500.
    func testFiveHundredScatteredEditsIn20kLinesStayExact() {
        let (left, right) = scattered(count: 20_000, edits: 500)
        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
        XCTAssertEqual(counts(result).match, 19_500)
    }

    /// The other half of the claim: the ceiling must still be reached on
    /// RELATEDNESS. Two disjoint 2000-line files are edit distance 4000 out of a
    /// maximum of 4000 — nothing about them is a version of the other — and they
    /// must still fall back to the interleaved heuristic that lets
    /// `TextComparator` pair the lines up as changed.
    func testTwoDisjoint2000LineFilesStillFallBack() {
        let left = Array(0..<2_000)
        let right = Array(10_000..<12_000)
        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
        let tally = counts(result)
        XCTAssertEqual(tally.match, 0)
        for index in 0..<8 {
            if index.isMultiple(of: 2) {
                guard case .onlyInA = result[index] else { return XCTFail("op \(index) should be onlyInA") }
            } else {
                guard case .onlyInB = result[index] else { return XCTFail("op \(index) should be onlyInB") }
            }
        }
    }

    /// The boundary the old doc comment describes, kept: on a 2000-line pair,
    /// 75 % changed is edit distance 3000 and still exact.
    func testSeventyFivePercentChangedIn2000LinesStaysExact() {
        let left = Array(0..<2_000)
        var right = left
        for index in 0..<1_500 { right[index] = -(index + 1) }
        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
        XCTAssertEqual(counts(result).match, 500)
    }

    /// A pathological pair — two files drawn from a two-symbol alphabet — has
    /// long snakes on every diagonal, which is what the *time* budget is for.
    /// It must terminate, and it must still replay.
    func testHighlyRepetitiveInputsTerminateAndReplay() {
        var generator = SystemRandomNumberGenerator()
        let left = (0..<30_000).map { _ in Int.random(in: 0...1, using: &generator) }
        let right = (0..<30_000).map { _ in Int.random(in: 0...1, using: &generator) }
        let result = ops(left, right)
        XCTAssertTrue(replays(result, left, right))
    }
}

// MARK: - C3: the splice never writes a bare LF into a CRLF document

final class CompareBlockSpliceAppendTests: XCTestCase {

    /// The exact shape the fuzz found: `replaceStart == docLines.count`,
    /// `replaceCount == 0` — which is what `CompareTransferGeometry.replaceRange`
    /// returns for an all-filler block at the END of the file, i.e. the common
    /// "the other pane has extra lines at the bottom" transfer.
    ///
    /// The element that used to be last carries no `\r` (nothing follows it), so
    /// once the block is appended behind it the join produced `beta\ngamma`.
    func testCRLFAppendAtEndWithoutTrailingNewline() {
        let result = CompareBlockSplice.apply(
            text: "alpha\r\nbeta",
            replaceStart: 2,
            replaceCount: 0,
            replacementLines: ["gamma", "delta"],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "alpha\r\nbeta\r\ngamma\r\ndelta")
        XCTAssertFalse(containsBareLF(result ?? ""))
    }

    /// Same with a trailing newline: the document's last LF-split element is the
    /// empty string, which also carries no `\r`.
    func testCRLFAppendAtEndWithTrailingNewline() {
        let result = CompareBlockSplice.apply(
            text: "alpha\r\nbeta\r\n",
            replaceStart: 3,
            replaceCount: 0,
            replacementLines: ["gamma"],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "alpha\r\nbeta\r\n\r\ngamma")
        XCTAssertFalse(containsBareLF(result ?? ""))
    }

    /// Replacing the final line of a CRLF document keeps it unterminated.
    func testCRLFReplaceOfTheFinalLine() {
        let result = CompareBlockSplice.apply(
            text: "alpha\r\nbeta",
            replaceStart: 1,
            replaceCount: 1,
            replacementLines: ["B1", "B2"],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "alpha\r\nB1\r\nB2")
        XCTAssertFalse(containsBareLF(result ?? ""))
    }

    /// Seeded port of the auditor's 40 000-case fuzz: `apply` against a naive
    /// "split on the document's own terminator, `replaceSubrange`, join" model.
    /// The documents are pure (one line ending, no stray LF in a CRLF file), which
    /// is the only regime where the two splitters index the same array — and the
    /// regime every real transfer is in.
    func testSpliceAgreesWithTheNaiveModel() {
        var generator = CompareAudit2RNG(state: 0xC0FFEE_1234)
        var cases = 0
        for lineEnding in [TextLineEnding.lf, .crlf, .cr] {
            let terminator = lineEnding.sequence
            for trailingNewline in [false, true] {
                for lineCount in 1...6 {
                    let docLines = (0..<lineCount).map { "line\($0)" }
                    var text = docLines.joined(separator: terminator)
                    if trailingNewline { text += terminator }
                    let elementCount = trailingNewline ? lineCount + 1 : lineCount

                    for replaceStart in 0...elementCount {
                        for replaceCount in 0...(elementCount - replaceStart) {
                            for incomingCount in 0...2 {
                                let incoming = (0..<incomingCount).map { "new\($0)-\(generator.next() % 10)" }
                                guard replaceCount > 0 || !incoming.isEmpty else { continue }
                                cases += 1

                                var model = trailingNewline ? docLines + [""] : docLines
                                model.replaceSubrange(
                                    replaceStart ..< (replaceStart + replaceCount), with: incoming
                                )
                                let expected = model.joined(separator: terminator)

                                let actual = CompareBlockSplice.apply(
                                    text: text,
                                    replaceStart: replaceStart,
                                    replaceCount: replaceCount,
                                    replacementLines: incoming,
                                    lineEnding: lineEnding
                                )
                                XCTAssertEqual(
                                    actual, expected,
                                    "\(lineEnding) trailing=\(trailingNewline) start=\(replaceStart) "
                                    + "count=\(replaceCount) incoming=\(incoming)"
                                )
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 1_000, "the sweep must actually cover something")
    }

    private func containsBareLF(_ text: String) -> Bool {
        let units = Array(text.utf8)
        for index in units.indices where units[index] == 0x0A {
            if index == units.startIndex || units[index - 1] != 0x0D { return true }
        }
        return false
    }
}

// MARK: - C1: the incremental storage write must leave `.isFillerLine` exact

@MainActor
final class CompareIncrementalFillerTests: XCTestCase {

    /// One pane's display, materialised the way `applyCompareDisplay` does.
    private func display(left: String, right: String, leftSide: Bool)
        -> (attributed: NSMutableAttributedString, runs: [NSRange]) {
        let probe = CompareBenchmarkSeam.displayProbe(left: left, right: right, leftSide: leftSide)
        let attributed = NSMutableAttributedString(string: probe.displayText)
        for range in probe.fillerRanges {
            attributed.addAttribute(.isFillerLine, value: true, range: range)
        }
        let runs = CompareStorageWrite.fillerRuns(
            rowRanges: probe.rows.map(\.range), isFiller: probe.rows.map(\.isFiller)
        )
        return (attributed, runs)
    }

    /// Writes a display into `storage` through the real incremental path.
    @discardableResult
    private func write(left: String, right: String, leftSide: Bool, into storage: NSTextStorage) -> Bool {
        let built = display(left: left, right: right, leftSide: leftSide)
        return CompareStorageWrite.perform(
            display: built.attributed, fillerRuns: built.runs, into: storage, willReplaceText: {}
        ).replacedText
    }

    private func fillerFlags(of storage: NSTextStorage) -> [Bool] {
        (0..<storage.length).map {
            storage.attribute(.isFillerLine, at: $0, effectiveRange: nil) != nil
        }
    }

    private func editor() -> EditorTextView {
        EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    }

    /// The auditor's T1. Both displays are the same five characters — the filler
    /// just moves from row 1 to row 2 — so the incremental write replaces
    /// `[2,4)` and the last `"\n"` keeps the REAL attributes it carried as the
    /// tail of row `b`. `realText` then sees three real lines and hands
    /// `document.text` a trailing blank line the user never typed.
    func testFillerMovingPastARealBlankLineDoesNotAddALine() {
        let left = "a\nb"
        let storage = NSTextStorage()
        write(left: left, right: "a\nX\nb", leftSide: true, into: storage)
        write(left: left, right: "a\nb\nX", leftSide: true, into: storage)

        XCTAssertEqual(editor().realText(from: storage), left,
                       "the left document must not grow a blank line it never had")
    }

    /// The loss direction: a document whose own trailing blank line is deleted.
    func testFillerMovingPastARealBlankLineDoesNotDropALine() {
        let left = "a\n"
        let storage = NSTextStorage()
        write(left: left, right: "a\nb\nc", leftSide: true, into: storage)
        write(left: left, right: "b\na", leftSide: true, into: storage)

        XCTAssertEqual(editor().realText(from: storage), left,
                       "the left document's blank line must survive a peer-driven rebuild")
    }

    /// The second symptom of the same stale flag: `touchesFillerLine` reads the
    /// attribute at the EDIT location, so a flag left inside a real line refuses
    /// edits there — after that peer edit the user could not type at the end of
    /// the line `a`.
    func testNoStaleFillerFlagIsLeftInsideARealLine() {
        let left = "a"
        let storage = NSTextStorage()
        write(left: left, right: "x\na\nb", leftSide: true, into: storage)
        write(left: left, right: "a", leftSide: true, into: storage)

        let fresh = NSTextStorage()
        write(left: left, right: "a", leftSide: true, into: fresh)
        XCTAssertEqual(fillerFlags(of: storage), fillerFlags(of: fresh))
    }

    /// The property, swept: for every ordered pair of peer documents, a display
    /// applied on top of another must leave the storage attribute-for-attribute
    /// what a clean build gives, and `realText` must still be the document.
    ///
    /// This is the auditor's F4b, narrowed to a corpus that runs in a second.
    func testEveryPeerTransitionRoundTripsAndMatchesACleanBuild() {
        let documents = [
            "a", "a\n", "a\nb", "a\nb\nc", "a\n\nb", "\na", "b\na", "a\nb\nX",
            "a\nX\nb", "x\na\nb", "", "a\r\nb", "a\rb\nc", "ก\nข", "a\nb\nc\nd"
        ]
        let view = editor()
        var checked = 0
        for own in documents {
            for leftSide in [true, false] {
                for first in documents {
                    for second in documents where second != first {
                        let storage = NSTextStorage()
                        let left1 = leftSide ? own : first
                        let right1 = leftSide ? first : own
                        let left2 = leftSide ? own : second
                        let right2 = leftSide ? second : own
                        write(left: left1, right: right1, leftSide: leftSide, into: storage)
                        write(left: left2, right: right2, leftSide: leftSide, into: storage)

                        let fresh = NSTextStorage()
                        write(left: left2, right: right2, leftSide: leftSide, into: fresh)

                        checked += 1
                        XCTAssertEqual(storage.string, fresh.string,
                                       "own=\(own.debugDescription) \(first.debugDescription) -> \(second.debugDescription)")
                        XCTAssertEqual(fillerFlags(of: storage), fillerFlags(of: fresh),
                                       "own=\(own.debugDescription) \(first.debugDescription) -> \(second.debugDescription)")
                        XCTAssertEqual(view.realText(from: storage), own,
                                       "own=\(own.debugDescription) \(first.debugDescription) -> \(second.debugDescription)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1_000)
    }

    /// The reconcile is a diff, not a rewrite, so the interval sweep under it is
    /// worth pinning on its own.
    func testDifferencesSweepsBothLists() {
        func check(_ desired: [NSRange], _ actual: [NSRange],
                   add: [NSRange], remove: [NSRange], line: UInt = #line) {
            let work = CompareStorageWrite.differences(desired: desired, actual: actual)
            XCTAssertEqual(work.add, add, "add", line: line)
            XCTAssertEqual(work.remove, remove, "remove", line: line)
        }
        check([], [], add: [], remove: [])
        check([NSRange(location: 0, length: 4)], [NSRange(location: 0, length: 4)],
              add: [], remove: [])
        check([NSRange(location: 0, length: 4)], [],
              add: [NSRange(location: 0, length: 4)], remove: [])
        check([], [NSRange(location: 2, length: 3)],
              add: [], remove: [NSRange(location: 2, length: 3)])
        // Shifted by one: the overlap is agreed, the two ends are not.
        check([NSRange(location: 2, length: 4)], [NSRange(location: 4, length: 4)],
              add: [NSRange(location: 2, length: 2)], remove: [NSRange(location: 6, length: 2)])
        // Two desired runs against one wide actual run.
        check([NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)],
              [NSRange(location: 0, length: 8)],
              add: [], remove: [NSRange(location: 2, length: 4)])
        // Adjacent desired runs coalesce in the emitted work.
        check([NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)], [],
              add: [NSRange(location: 0, length: 4)], remove: [])
    }

    /// Adjacent filler rows are one run, which is what `enumerateAttribute`
    /// reports for them — otherwise every reconcile would find a difference.
    func testFillerRunsMergeAdjacentRows() {
        let rows = [NSRange(location: 0, length: 2), NSRange(location: 2, length: 1),
                    NSRange(location: 3, length: 4), NSRange(location: 7, length: 1)]
        let runs = CompareStorageWrite.fillerRuns(rowRanges: rows,
                                                  isFiller: [true, true, false, true])
        XCTAssertEqual(runs, [NSRange(location: 0, length: 3), NSRange(location: 7, length: 1)])
    }
}

// MARK: - C7: a rebuild is only current while BOTH texts still match

final class CompareApplyGuardPeerTests: XCTestCase {

    func testAFreshRebuildIsAccepted() {
        XCTAssertTrue(CompareApplyGuard.shouldApply(
            builtFrom: "L1", peerSnapshot: "R1", documentText: "L1", peerText: "R1"
        ))
    }

    func testARebuildBuiltFromAnOlderOwnTextIsRefused() {
        XCTAssertFalse(CompareApplyGuard.shouldApply(
            builtFrom: "L1", peerSnapshot: "R1", documentText: "L2", peerText: "R1"
        ))
    }

    /// The finding. The left pane's own text never moved, so the old one-sided
    /// guard applied a rebuild for (L1, R2) while the right pane — whose own text
    /// had gone on to R3 — correctly refused its copy and kept rendering
    /// (L1, R1). The two panes then held different row arrays, with the transfer
    /// arrows live over an invariant ("row N is aligned across panes") that no
    /// longer held.
    func testARebuildBuiltFromAnOlderPeerTextIsRefused() {
        XCTAssertFalse(CompareApplyGuard.shouldApply(
            builtFrom: "L1", peerSnapshot: "R2", documentText: "L1", peerText: "R3"
        ))
    }

    func testARebuildIsRefusedWhenThePeerIsGone() {
        XCTAssertFalse(CompareApplyGuard.shouldApply(
            builtFrom: "L1", peerSnapshot: "R1", documentText: "L1", peerText: nil
        ))
    }
}

// MARK: - C2 / C6 / C8: what a transfer arrow may act on

// The seam these drive is a DEBUG one (the coordinator is file-private), so the
// tests have to be too — a Release test build otherwise fails to compile.
#if DEBUG
@MainActor
final class CompareTransferStalenessTests: XCTestCase {

    private func lines(_ values: [String]) -> String { values.joined(separator: "\n") }

    /// Baseline: with both panes rebuilt and neither document touched since, the
    /// arrow works. Everything below is this test with one thing changed.
    func testAnArrowOnCurrentRowsTransfersTheBlock() {
        let pair = CompareCoordinatorAuditSeam.PanePair(
            left: lines(["alpha", "beta", "gamma"]),
            right: lines(["alpha", "BETA", "gamma"])
        )
        XCTAssertTrue(pair.rebuild())
        XCTAssertTrue(pair.arrowsAreLive(left: true))

        pair.clickTransferArrow(left: true, displayRows: NSRange(location: 1, length: 1))
        XCTAssertEqual(pair.postedTransfers.count, 1)
        XCTAssertEqual(pair.postedTransfers.first?.lines, ["beta"])

        pair.deliver(pair.postedTransfers[0])
        XCTAssertEqual(pair.rightDocument.text, lines(["alpha", "beta", "gamma"]))
    }

    /// C6. `document.text` is updated synchronously on every keystroke; the row
    /// array only when the rebuild behind the 0.08–0.35 s debounce finishes. In
    /// that window every `realLineNumber` below an inserted line is one too
    /// small, so the arrow sends the block above the one it is drawn beside.
    func testAnArrowClickedInsideTheRebuildDebounceIsRefused() {
        let pair = CompareCoordinatorAuditSeam.PanePair(
            left: lines(["alpha", "beta", "gamma"]),
            right: lines(["alpha", "BETA", "gamma"])
        )
        XCTAssertTrue(pair.rebuild())

        pair.type(left: true, at: 0, "NEW\n")
        XCTAssertFalse(pair.arrowsAreLive(left: true),
                       "the gutter must stop offering arrows it can no longer place")
        pair.clickTransferArrow(left: true, displayRows: NSRange(location: 1, length: 1))
        XCTAssertTrue(pair.postedTransfers.isEmpty)
    }

    /// C6's second half: `applyCompareBlockTransfer` runs synchronously while the
    /// rebuild behind it does not, so a second click on an insertion arrow could
    /// still see the old `(anchor, 0)` and splice again. The first transfer bumps
    /// the receiving document's revision, which is what now stops it.
    func testARepeatedTransferBeforeTheRebuildLandsIsIdempotent() {
        let pair = CompareCoordinatorAuditSeam.PanePair(
            left: lines(["alpha", "beta", "gamma", "delta"]),
            right: lines(["alpha", "beta"])
        )
        XCTAssertTrue(pair.rebuild())

        pair.clickTransferArrow(left: true, displayRows: NSRange(location: 2, length: 2))
        XCTAssertEqual(pair.postedTransfers.count, 1)
        pair.deliver(pair.postedTransfers[0])
        let afterFirst = pair.rightDocument.text
        XCTAssertEqual(afterFirst, lines(["alpha", "beta", "gamma", "delta"]))

        // The impatient second click, before either pane has rebuilt.
        pair.deliver(pair.postedTransfers[0])
        XCTAssertEqual(pair.rightDocument.text, afterFirst,
                       "a repeat delivery must not splice the block twice")
    }

    /// C2. A CR-only document is ONE row to `LineHashing.splitLines` and N lines
    /// to `CompareBlockSplice`, so `(0, 1)` replaced the target's first CR-line
    /// with the sender's entire file. The rows still render; the arrows do not.
    func testCROnlyDocumentsGetNoTransferArrows() {
        let pair = CompareCoordinatorAuditSeam.PanePair(
            left: "alpha\rbeta\rgamma",
            right: "alpha\rbetaX\rgamma",
            lineEnding: .cr
        )
        XCTAssertTrue(pair.rebuild())
        XCTAssertFalse(pair.arrowsAreLive(left: true))
        XCTAssertFalse(pair.arrowsAreLive(left: false))

        pair.clickTransferArrow(left: true, displayRows: NSRange(location: 0, length: 1))
        XCTAssertTrue(pair.postedTransfers.isEmpty)
        XCTAssertEqual(pair.rightDocument.text, "alpha\rbetaX\rgamma",
                       "the right document must not gain the whole left file")
    }

    /// C8. The `*` markers were keyed by display row, and a peer edit that adds a
    /// filler above the marked line moves every row below it — so the marker sat
    /// beside a line the user never touched.
    func testEditedLineMarkersFollowTheRealLineAcrossARebuild() {
        let pair = CompareCoordinatorAuditSeam.PanePair(
            left: lines(["alpha", "beta", "gamma"]),
            right: lines(["alpha", "beta", "gamma"])
        )
        XCTAssertTrue(pair.rebuild())
        // The user types on "gamma", display row 3 (no fillers yet).
        pair.noteEdit(left: true, atDisplayRow: 3)
        XCTAssertEqual(pair.markedRows(left: true), [3])

        // The peer gains a line at the top, so the left pane grows a filler above
        // everything and "gamma" is display row 4.
        pair.setDocumentText(left: false, to: lines(["NEW", "alpha", "beta", "gamma"]))
        XCTAssertTrue(pair.rebuild())
        XCTAssertEqual(pair.markedRows(left: true), [4],
                       "the marker must follow the line, not the row it used to sit on")
    }

    /// C5. Compare rows split on LF only. TextKit also treats U+2028 as a line
    /// break, so using the normal cursor put the marker one row below the diff.
    func testEditedLineMarkerCountsCompareRowsByLineFeed() {
        let text = "alpha\u{2028}beta\ngamma"
        let pair = CompareCoordinatorAuditSeam.PanePair(left: text, right: text)
        XCTAssertTrue(pair.rebuild())

        let insertion = ("alpha\u{2028}be" as NSString).length
        pair.type(left: true, at: insertion, "X")

        XCTAssertEqual(pair.markedRows(left: true), [1])
    }

    /// CP2. Word-level backgrounds are temporary attributes, and installing
    /// one for every changed word made each settled keystroke cost the whole
    /// document even though only a screenful can be drawn.
    func testCompareWordHighlightsArePaintedOnlyNearTheViewport() {
        let left = (0..<600).map { "interface \($0) description alpha" }.joined(separator: "\n")
        let right = (0..<600).map { "interface \($0) description beta" }.joined(separator: "\n")
        let pair = CompareCoordinatorAuditSeam.PanePair(left: left, right: right)
        XCTAssertTrue(pair.rebuild())

        let ns = left as NSString
        let first = ns.range(of: "alpha").location
        let last = ns.range(of: "alpha", options: .backwards).location
        XCTAssertNotNil(pair.wordBackground(left: true, at: first))
        XCTAssertNil(pair.wordBackground(left: true, at: last),
                     "an offscreen word must wait for the scroll paint")
    }
}

#endif

/// Deterministic PRNG so a failing sweep is reproducible.
struct CompareAudit2RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
