import XCTest
import AppKit
@testable import SheepText

/// ⇧⌘D on a CRLF file inserted a blank line between the original and its copy.
///
/// `duplicateCurrentLines` decided whether a line already carried a terminator
/// with `lineText.hasSuffix("\n") || lineText.hasSuffix("\r")`. A CRLF line ends
/// in a SINGLE Swift `Character` equal to neither operand, so the answer was
/// false for every line of a CRLF document and the duplicate was prefixed with
/// another line ending it did not need. The seventh instance of this codebase's
/// recurring line-ending bug — see CLAUDE.md, "Line endings".
///
/// The test target does not set `SWIFT_DEFAULT_ACTOR_ISOLATION`, so a class that
/// touches AppKit declares `@MainActor` itself.
@MainActor
final class DuplicateLineLineEndingTests: XCTestCase {

    /// `EditorTextView.document` is a WEAK reference: bind the returned document in
    /// every test, or it deallocates, `duplicateCurrentLines` falls back to a bare
    /// LF line ending, and the test measures the wrong thing.
    private func makeTextView(_ text: String) -> (NSWindow, EditorTextView, Document) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.allowsUndo = true
        tv.string = text
        let document = Document(
            url: nil, initialText: text, encoding: .utf8, hasBOM: false
        )
        tv.document = document
        window.contentView = tv
        window.makeFirstResponder(tv)
        return (window, tv, document)
    }

    func testDuplicateLineOnCRLFDocumentAddsNoBlankLine() {
        let (_, tv, document) = makeTextView("line one\r\nline two\r\n")
        XCTAssertEqual(document.lineEnding, .crlf, "fixture is not a CRLF document")

        tv.setSelectedRange(NSRange(location: 2, length: 0))   // inside "line one"
        tv.duplicateCurrentLines()

        XCTAssertEqual(tv.string, "line one\r\nline one\r\nline two\r\n")
    }

    func testDuplicateLineOnLFDocumentIsUnchanged() {
        let (_, tv, document) = makeTextView("line one\nline two\n")
        XCTAssertEqual(document.lineEnding, .lf, "fixture is not an LF document")
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.duplicateCurrentLines()

        XCTAssertEqual(tv.string, "line one\nline one\nline two\n")
    }

    /// The last line of a file carries no terminator, so the copy needs one in
    /// front of it — in the document's own line ending, not a bare LF.
    func testDuplicateFinalUnterminatedLineOnCRLFUsesCRLF() {
        let (_, tv, document) = makeTextView("line one\r\nlast")
        XCTAssertEqual(document.lineEnding, .crlf, "fixture is not a CRLF document")
        tv.setSelectedRange(NSRange(location: 12, length: 0))   // inside "last"
        tv.duplicateCurrentLines()

        XCTAssertEqual(tv.string, "line one\r\nlast\r\nlast")
    }

    /// A selection spanning two CRLF lines duplicates both, with no blank line
    /// anywhere in the result.
    func testDuplicateMultiLineSelectionOnCRLFDocument() {
        let (_, tv, document) = makeTextView("a\r\nb\r\nc\r\n")
        XCTAssertEqual(document.lineEnding, .crlf, "fixture is not a CRLF document")
        tv.setSelectedRange(NSRange(location: 0, length: 6))   // "a\r\nb\r\n"
        tv.duplicateCurrentLines()

        XCTAssertEqual(tv.string, "a\r\nb\r\na\r\nb\r\nc\r\n")
    }
}
