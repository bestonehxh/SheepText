import XCTest
@testable import SheepText

/// Regression cover for the compare block transfer's line endings: a CRLF document
/// receiving lines from an LF document used to end up silently mixed.
final class CompareBlockSpliceTests: XCTestCase {

    func testNeutralizeStripsOnlyTrailingCR() {
        XCTAssertEqual(CompareBlockSplice.neutralize("alpha\r"), "alpha")
        XCTAssertEqual(CompareBlockSplice.neutralize("alpha"), "alpha")
        XCTAssertEqual(CompareBlockSplice.neutralize("al\rpha"), "al\rpha")
        XCTAssertEqual(CompareBlockSplice.neutralize(""), "")
    }

    func testLFDocumentIsUnchangedInShape() {
        let result = CompareBlockSplice.apply(
            text: "a\nb\nc\n",
            replaceStart: 1,
            replaceCount: 1,
            replacementLines: ["B"],
            lineEnding: .lf
        )
        XCTAssertEqual(result, "a\nB\nc\n")
    }

    func testCRLFDocumentKeepsCRLFAfterReceivingLFLines() {
        let result = CompareBlockSplice.apply(
            text: "a\r\nb\r\nc\r\n",
            replaceStart: 1,
            replaceCount: 1,
            replacementLines: ["B", "B2"],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "a\r\nB\r\nB2\r\nc\r\n")
        XCTAssertFalse(containsBareLF(result ?? ""), "a bare LF leaked into a CRLF document")
    }

    func testCRLFDocumentWithoutFinalNewlineKeepsLastLineUnterminated() {
        let result = CompareBlockSplice.apply(
            text: "a\r\nb",
            replaceStart: 1,
            replaceCount: 1,
            replacementLines: ["B"],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "a\r\nB")
    }

    func testCRLFInsertionWithoutReplacement() {
        let result = CompareBlockSplice.apply(
            text: "a\r\nb\r\n",
            replaceStart: 1,
            replaceCount: 0,
            replacementLines: ["X"],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "a\r\nX\r\nb\r\n")
    }

    func testDeletionRemovesLines() {
        let result = CompareBlockSplice.apply(
            text: "a\r\nb\r\nc\r\n",
            replaceStart: 1,
            replaceCount: 1,
            replacementLines: [],
            lineEnding: .crlf
        )
        XCTAssertEqual(result, "a\r\nc\r\n")
    }

    // MARK: - CR-only documents (audit C7)
    //
    // `apply` split every document on "\n". A CR-only document contains none, so
    // it was a single element: the range guard rejected every block except one at
    // line 0, and that one rewrote the whole file. Splitting on the document's own
    // separator makes mid-file blocks address the lines they name.

    func testCRDocumentMidFileReplace() {
        let result = CompareBlockSplice.apply(
            text: "a\rb\rc\rd",
            replaceStart: 1,
            replaceCount: 2,
            replacementLines: ["X", "Y", "Z"],
            lineEnding: .cr
        )
        XCTAssertEqual(result, "a\rX\rY\rZ\rd")
        XCTAssertFalse((result ?? "").contains("\n"), "an LF leaked into a CR-only document")
    }

    func testCRDocumentMidFileSingleLineReplace() {
        XCTAssertEqual(
            CompareBlockSplice.apply(
                text: "a\rb\rc\r", replaceStart: 1, replaceCount: 1,
                replacementLines: ["B"], lineEnding: .cr
            ),
            "a\rB\rc\r"
        )
    }

    func testCRDocumentMidFileInsertion() {
        XCTAssertEqual(
            CompareBlockSplice.apply(
                text: "a\rb\rc", replaceStart: 2, replaceCount: 0,
                replacementLines: ["X"], lineEnding: .cr
            ),
            "a\rb\rX\rc"
        )
    }

    func testCRDocumentMidFileDeletion() {
        XCTAssertEqual(
            CompareBlockSplice.apply(
                text: "a\rb\rc\rd", replaceStart: 1, replaceCount: 2,
                replacementLines: [], lineEnding: .cr
            ),
            "a\rd"
        )
    }

    func testCRDocumentLastLineReplace() {
        XCTAssertEqual(
            CompareBlockSplice.apply(
                text: "a\rb\rc", replaceStart: 2, replaceCount: 1,
                replacementLines: ["C"], lineEnding: .cr
            ),
            "a\rb\rC"
        )
    }

    func testCRDocumentOutOfRangeStillReturnsNil() {
        XCTAssertNil(CompareBlockSplice.apply(
            text: "a\rb\rc", replaceStart: 4, replaceCount: 1,
            replacementLines: ["X"], lineEnding: .cr
        ))
    }

    func testCRDocumentNeverGainsAnLF() {
        let result = CompareBlockSplice.apply(
            text: "a\rb\rc",
            replaceStart: 0,
            replaceCount: 1,
            replacementLines: ["X", "Y"],
            lineEnding: .cr
        )
        XCTAssertNotNil(result)
        XCTAssertFalse((result ?? "").contains("\n"), "an LF leaked into a CR-only document")
    }

    func testOutOfRangeAndNoOpReturnNil() {
        XCTAssertNil(CompareBlockSplice.apply(
            text: "a\nb\n", replaceStart: 9, replaceCount: 1,
            replacementLines: ["X"], lineEnding: .lf
        ))
        XCTAssertNil(CompareBlockSplice.apply(
            text: "a\nb\n", replaceStart: 1, replaceCount: 0,
            replacementLines: [], lineEnding: .lf
        ))
    }

    private func containsBareLF(_ text: String) -> Bool {
        let ns = text as NSString
        for i in 0..<ns.length where ns.character(at: i) == 10 {
            if i == 0 || ns.character(at: i - 1) != 13 { return true }
        }
        return false
    }
}
