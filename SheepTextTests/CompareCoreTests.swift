import XCTest
@testable import SheepText

/// Unit tests for the compare pipeline core: LineHashing, DiffCalc, TextComparator.
///
/// These existed as zero tests before (the SheepTextTests target had an empty
/// Sources phase), so every behaviour pinned here was previously unverified.
final class LineHashingTests: XCTestCase {

    // MARK: splitLines

    func testSplitLinesLF() {
        XCTAssertEqual(LineHashing.splitLines("a\nb\nc"), ["a", "b", "c"])
    }

    func testSplitLinesCRLF() {
        // Regression: Character-based split treated "\r\n" as one cluster and
        // returned a single element for an entire CRLF file.
        XCTAssertEqual(LineHashing.splitLines("a\r\nb\r\nc"), ["a\r", "b\r", "c"])
    }

    func testSplitLinesEmptyString() {
        XCTAssertEqual(LineHashing.splitLines(""), [""])
    }

    func testSplitLinesTrailingNewline() {
        XCTAssertEqual(LineHashing.splitLines("a\n"), ["a", ""])
    }

    func testSplitLinesLoneCRNotSplit() {
        XCTAssertEqual(LineHashing.splitLines("a\rb"), ["a\rb"])
    }

    func testSplitLinesUnicodeContent() {
        XCTAssertEqual(LineHashing.splitLines("สวัสดี\nครับ🐑"), ["สวัสดี", "ครับ🐑"])
    }

    // MARK: normalize

    func testNormalizeStripsTrailingCR() {
        let options = CompareOptions()
        XCTAssertEqual(LineHashing.normalize("hello\r", options: options), "hello")
    }

    func testNormalizeIgnoreChangedSpaces() {
        var options = CompareOptions()
        options.ignoreChangedSpaces = true
        XCTAssertEqual(LineHashing.normalize("  a   b\t ", options: options), "a b")
    }

    func testNormalizeIgnoreCase() {
        var options = CompareOptions()
        options.ignoreCase = true
        XCTAssertEqual(LineHashing.normalize("VLAN 100", options: options), "vlan 100")
    }

    // MARK: extractLines

    func testExtractLinesLineNumbersAreOneBased() {
        let lines = LineHashing.extractLines("x\ny", options: CompareOptions())
        XCTAssertEqual(lines.map(\.lineNumber), [1, 2])
        XCTAssertEqual(lines.map(\.raw), ["x", "y"])
    }

    func testCRLFAndLFTwinsHashEqual() {
        let options = CompareOptions()
        let crlf = LineHashing.extractLines("a\r\nb\r\n", options: options)
        let lf   = LineHashing.extractLines("a\nb\n", options: options)
        XCTAssertEqual(crlf.map(\.hash), lf.map(\.hash))
    }
}

final class DiffCalcTests: XCTestCase {

    private func ops(_ a: [Int], _ b: [Int]) -> [DiffOp<Int>] {
        DiffCalc.diff(a, b) { $0 == $1 }
    }

    func testEmptyInputs() {
        XCTAssertEqual(ops([], []).count, 0)
        guard case .onlyInB(let x) = ops([], [1]).first! else { return XCTFail() }
        XCTAssertEqual(x, 1)
        guard case .onlyInA(let y) = ops([1], []).first! else { return XCTFail() }
        XCTAssertEqual(y, 1)
    }

    func testIdenticalSequencesAllMatch() {
        let result = ops([1, 2, 3], [1, 2, 3])
        XCTAssertEqual(result.count, 3)
        for op in result {
            guard case .match = op else { return XCTFail("expected all matches") }
        }
    }

    func testInsertionInMiddle() {
        let result = ops([1, 2, 3], [1, 9, 2, 3])
        var matches = 0, inserts = 0
        for op in result {
            switch op {
            case .match: matches += 1
            case .onlyInB: inserts += 1
            case .onlyInA: XCTFail("unexpected deletion")
            }
        }
        XCTAssertEqual(matches, 3)
        XCTAssertEqual(inserts, 1)
    }

    func testDeletionInMiddle() {
        let result = ops([1, 9, 2, 3], [1, 2, 3])
        var matches = 0, deletes = 0
        for op in result {
            switch op {
            case .match: matches += 1
            case .onlyInA: deletes += 1
            case .onlyInB: XCTFail("unexpected insertion")
            }
        }
        XCTAssertEqual(matches, 3)
        XCTAssertEqual(deletes, 1)
    }

    /// 2101 x 2101 elements with one differing line at the end.
    ///
    /// This used to be the *fallback* case: `n*m > 4_000_000` sent it to
    /// `prefixSuffixDiff`, which happened to produce the right answer here
    /// because the difference is a single trailing line. Since the Myers rewrite
    /// (audit C2) the size no longer decides anything — the edit distance is 2,
    /// so this is now diffed exactly. The expected output is identical either
    /// way, which is exactly why it is worth keeping.
    func testHugeInputsWithOneTrailingDifference() {
        let a = Array(0..<2100) + [999999]      // 2101 elements
        let b = Array(0..<2100) + [888888]      // 2101 * 2101 > 4_000_000
        let result = ops(a, b)
        var matches = 0, deletes = 0, inserts = 0
        for op in result {
            switch op {
            case .match: matches += 1
            case .onlyInA: deletes += 1
            case .onlyInB: inserts += 1
            }
        }
        XCTAssertEqual(matches, 2100)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(inserts, 1)
    }

    /// Edit at the START of a file: the suffix trim must keep the op sequence
    /// correct (trailing elements still reported as matches at the END).
    func testSuffixTrimKeepsOpsCorrectForLeadingEdit() {
        let n = 300
        let tail = Array(1...n)
        let result = ops([999] + tail, [888] + tail)
        var matches = 0, deletes = 0, inserts = 0
        for op in result {
            switch op {
            case .match: matches += 1
            case .onlyInA: deletes += 1
            case .onlyInB: inserts += 1
            }
        }
        XCTAssertEqual(matches, n)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(inserts, 1)
        guard case .match(let a, let b) = result.last! else { return XCTFail("last op must be a match") }
        XCTAssertEqual(a, n)
        XCTAssertEqual(b, n)
    }

    /// Both prefix and suffix trimmed: the middle ops must keep their order.
    func testBothPrefixAndSuffixTrimmedKeepsMiddleCorrect() {
        let a = [0, 0] + [1, 2, 3] + [9, 9]
        let b = [0, 0] + [1, 7, 3] + [9, 9]
        let kinds = ops(a, b).map { op -> String in
            switch op {
            case .match: return "M"
            case .onlyInA: return "A"
            case .onlyInB: return "B"
            }
        }
        XCTAssertEqual(kinds, ["M", "M", "M", "A", "B", "M", "M", "M"])
    }

    func testFallbackInterleavesMiddleSoChangedPairingCanFire() {
        // Two fully different middles must come out interleaved A/B, not all-A
        // then all-B, otherwise TextComparator cannot form changed pairs.
        //
        // Updated for audit C2: the fallback is no longer chosen by INPUT SIZE
        // (the old `n*m > 4_000_000`, which this test used to reach with a
        // two-element middle) but by EDIT DISTANCE. So the middles here have to
        // be genuinely unrelated and large enough to exceed the Myers ceiling —
        // 1600 disjoint lines a side is edit distance 3200, above the 3000 cap.
        // A two-element middle is now diffed exactly instead, which is the point
        // of the rewrite.
        let prefix = Array(0..<50)
        let suffix = Array(500_000..<500_050)
        let a = prefix + Array(100_000..<101_600) + suffix
        let b = prefix + Array(200_000..<201_600) + suffix
        let result = ops(a, b)
        let middle = Array(result.dropFirst(prefix.count).dropLast(suffix.count))
        XCTAssertEqual(middle.count, 3_200, "the whole middle should be add/remove ops")
        for index in 0..<8 {
            if index.isMultiple(of: 2) {
                guard case .onlyInA = middle[index] else { return XCTFail("middle[\(index)] should be onlyInA") }
            } else {
                guard case .onlyInB = middle[index] else { return XCTFail("middle[\(index)] should be onlyInB") }
            }
        }
    }
}

final class TextComparatorTests: XCTestCase {

    private func summary(_ a: String, _ b: String, options: CompareOptions = CompareOptions()) -> CompareSummary {
        guard case .mismatch(let s) = TextComparator.compare(a, b, options: options) else {
            XCTFail("expected mismatch")
            return CompareSummary(added: 0, removed: 0, changed: 0, blocks: [])
        }
        return s
    }

    func testIdenticalTextsMatch() {
        guard case .match = TextComparator.compare("a\nb\nc", "a\nb\nc", options: CompareOptions()) else {
            return XCTFail("expected .match")
        }
    }

    func testIdenticalModuloLineEndingsMatch() {
        guard case .match = TextComparator.compare("a\r\nb\r\n", "a\nb\n", options: CompareOptions()) else {
            return XCTFail("CRLF vs LF twin should match")
        }
    }

    func testPureAddition() {
        let s = summary("a\nc", "a\nb\nc")
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 0)
        XCTAssertEqual(s.changed, 0)
        guard case .onlyInB(let range) = s.blocks[1] else { return XCTFail("expected onlyInB block") }
        XCTAssertEqual(range, 2...2)
    }

    func testPureDeletion() {
        let s = summary("a\nb\nc", "a\nc")
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(s.added, 0)
        guard case .onlyInA(let range) = s.blocks[1] else { return XCTFail("expected onlyInA block") }
        XCTAssertEqual(range, 2...2)
    }

    func testSimilarLineClassifiedChanged() {
        // One line slightly edited → resemblance ≥ 50 % → .changed, not add+remove.
        let s = summary("vlan 100", "vlan 101")
        XCTAssertEqual(s.changed, 1)
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
        guard case .changed(let aLines, let bLines) = s.blocks.first else {
            return XCTFail("expected .changed block")
        }
        XCTAssertEqual(aLines.map(\.lineNumber), [1])
        XCTAssertEqual(bLines.map(\.lineNumber), [1])
    }

    func testUnrelatedLineSplitsIntoAddAndRemove() {
        let s = summary("the quick brown fox jumps over", "xqz")
        XCTAssertEqual(s.changed, 0)
        XCTAssertEqual(s.added, 1)
        XCTAssertEqual(s.removed, 1)
    }

    func testBFirstOrderingDetectedAsChangedCandidate() {
        // The LCS backtracker can emit onlyInB before onlyInA; the comparator
        // must still consider the pair a changed-block candidate.
        let s = summary("alpha beta gamma delta", "alpha beta gamma deltx")
        XCTAssertEqual(s.changed, 1)
    }

    func testIgnoreCaseOption() {
        var options = CompareOptions()
        options.ignoreCase = true
        guard case .match = TextComparator.compare("VLAN 100", "vlan 100", options: options) else {
            return XCTFail("ignoreCase should make these match")
        }
    }

    func testIgnoreChangedSpacesOption() {
        var options = CompareOptions()
        options.ignoreChangedSpaces = true
        guard case .match = TextComparator.compare("a   b", "a b", options: options) else {
            return XCTFail("ignoreChangedSpaces should make these match")
        }
    }

    func testMatchBlocksCarryCorrectLineRanges() {
        let s = summary("a\nb\nc\nd", "a\nX\nc\nd")
        // Blocks: match(1...1), changed/only-pair for line 2, match(3...4)
        guard case .match(let a1, let b1) = s.blocks.first else { return XCTFail() }
        XCTAssertEqual(a1, 1...1)
        XCTAssertEqual(b1, 1...1)
        guard case .match(let a2, let b2) = s.blocks.last else { return XCTFail() }
        XCTAssertEqual(a2, 3...4)
        XCTAssertEqual(b2, 3...4)
    }

    /// A large CRLF file vs its LF twin must not collapse into one giant
    /// changed block (the 29-second full-file regression).
    func testLargeCRLFFileDiffsLineByLine() {
        let lfLines = (1...500).map { "line \($0)" }
        let lf = lfLines.joined(separator: "\n")
        var crlfLines = lfLines
        crlfLines[250] = "line 251 edited"
        let crlf = crlfLines.joined(separator: "\r\n")
        let s = summary(lf, crlf)
        XCTAssertEqual(s.changed, 1, "only one line should be flagged")
        XCTAssertEqual(s.added, 0)
        XCTAssertEqual(s.removed, 0)
    }

    func testEmptyVsNonEmpty() {
        // "" splits to one empty line [""], "a\nb" splits to ["a", "b"].
        // Resemblance is 0 %, so this is one removal + two additions.
        let s = summary("", "a\nb")
        XCTAssertEqual(s.removed, 1)
        XCTAssertEqual(s.added, 2)
    }
}

// MARK: - Multi-cursor undo (QA repro, 2026-08-23)

/// Repro for "⌘D then Return then ⌘Z leaves the text changed and selects
/// everything" reported during manual QA. Driven through a real window so the
/// text view finds the window's undo manager on the responder chain.
@MainActor
final class MultiCursorUndoTests: XCTestCase {

    private func makeTextView(_ text: String) -> (NSWindow, EditorTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.allowsUndo = true
        tv.string = text
        window.contentView = tv
        window.makeFirstResponder(tv)
        return (window, tv)
    }

    func testSingleCursorTypingUndoRestoresText() {
        let (window, tv) = makeTextView("alpha\nbeta\n")
        let before = tv.string
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "X\nbeta\n")
        window.undoManager?.undo()
        XCTAssertEqual(tv.string, before, "single-cursor undo did not restore the text")
    }

    func testMultiCursorNewlineUndoRestoresText() {
        let (window, tv) = makeTextView("print one\nprint two\nprint three\n")
        let before = tv.string
        let r1 = (before as NSString).range(of: "print")
        let r2 = (before as NSString).range(of: "print", options: [], range: NSRange(location: r1.upperBound, length: before.utf16.count - r1.upperBound))
        tv.selectedRanges = [NSValue(range: r1), NSValue(range: r2)]
        XCTAssertEqual(tv.selectedRanges.count, 2)

        tv.insertNewline(nil)
        XCTAssertNotEqual(tv.string, before, "the edit itself did not happen")

        window.undoManager?.undo()
        XCTAssertEqual(tv.string, before, "multi-cursor undo did not restore the text")
    }
}
