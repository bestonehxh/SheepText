//
//  MarkdownTreeFenceTests.swift
//  Markdown fenced code blocks come from the tree, not from a document-wide
//  regex — so markdown takes the same incremental path as every other
//  tree-sitter language.
//
//  Two things are under test and they are not the same thing:
//
//  1. **What gets highlighted.** The grammar's reading of a fence is
//     CommonMark's, and it differs from the old regex in four places: an
//     unclosed fence runs to EOF, `~~~` is a fence, an opener may be indented
//     up to three spaces, and an info string may carry more than the language
//     word. Each has a test that names an offset and the style expected there.
//
//  2. **The changed-ranges contract** — "the previous result and this one
//     differ only inside these ranges". Markdown used to opt out of it by
//     always returning nil. It no longer does, so every fence-shaped edit is
//     checked twice: the incremental run list must equal a clean parse's, and
//     everything outside the reported ranges must be untouched.
//

import AppKit
import XCTest
@testable import SheepText

final class MarkdownTreeFenceTests: XCTestCase {

    // MARK: - Helpers

    private func runs(_ text: String, documentID: UUID? = nil) -> [HighlightRun] {
        guard let result = SyntaxEngine.shared.runsImmediately(
            text: text, language: "markdown", documentID: documentID
        ) else {
            XCTFail("markdown highlighter returned nil")
            return []
        }
        return result.runs
    }

    private func style(of text: String, at location: Int) -> HighlightStyleID {
        HighlightRunList.style(at: location, in: runs(text))
    }

    /// Offset of `needle` in `haystack`, as a UTF-16 index.
    private func offset(of needle: String, in haystack: String) -> Int {
        let range = (haystack as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "fixture is missing \(needle)")
        return range.location
    }

    /// The style the Swift grammar gives the `let` keyword, resolved from a
    /// pure-Swift pass so the assertion does not depend on which capture name
    /// the grammar happens to use.
    private lazy var swiftLetStyle: HighlightStyleID = {
        guard let result = SyntaxEngine.shared.runsImmediately(
            text: "let value = 1\n", language: "swift"
        ) else {
            XCTFail("swift highlighter returned nil")
            return HighlightStyleTable.none
        }
        let style = HighlightRunList.style(at: 0, in: result.runs)
        XCTAssertNotEqual(style, HighlightStyleTable.none, "swift `let` must carry a style")
        return style
    }()

    /// The style a fence body carries when nothing has injected into it: the
    /// markdown grammar's own `@text.literal` on `fenced_code_block`.
    private lazy var untaggedFenceBodyStyle: HighlightStyleID = {
        let text = "```\nlet value = 1\n```\n"
        return HighlightRunList.style(at: offset(of: "let value", in: text), in: runs(text))
    }()

    /// UTF-16 (oldRange, newLength) of the single replacement between two texts.
    private func editBetween(_ before: String, _ after: String) -> (old: NSRange, newLength: Int) {
        let old = before as NSString
        let new = after as NSString
        var prefix = 0
        while prefix < min(old.length, new.length),
              old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        return (NSRange(location: prefix, length: old.length - suffix - prefix),
                new.length - suffix - prefix)
    }

    /// The whole contract, for one edit made inside one session.
    ///
    /// `previous` is the run list the session last handed out for `before`.
    /// Returns the run list for `after`, so a caller can walk a script of edits.
    @discardableResult
    private func assertContract(
        documentID: UUID,
        previous: [HighlightRun],
        before: String,
        after: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [HighlightRun] {
        guard let incremental = SyntaxEngine.shared.runsImmediately(
            text: after, language: "markdown", documentID: documentID
        ) else {
            XCTFail("\(label): incremental pass returned nil", file: file, line: line)
            return []
        }
        guard let clean = SyntaxEngine.shared.runsImmediately(text: after, language: "markdown") else {
            XCTFail("\(label): clean pass returned nil", file: file, line: line)
            return []
        }

        XCTAssertEqual(
            incremental.runs, clean.runs,
            "\(label): incremental run list diverged from a clean parse",
            file: file, line: line
        )

        guard let ranges = incremental.changedRanges else { return incremental.runs }

        // Everything the engine did NOT report as changed must be exactly what
        // the previous pass said, carried across the edit.
        let edit = editBetween(before, after)
        let shifted = HighlightRunList.shifting(previous, replacing: edit.old, withLength: edit.newLength)
        let length = (after as NSString).length
        var reported = IndexSet()
        for range in ranges { reported.insert(integersIn: range.location..<min(NSMaxRange(range), length)) }

        for index in 0..<length where !reported.contains(index) {
            let old = HighlightRunList.style(at: index, in: shifted)
            let new = HighlightRunList.style(at: index, in: incremental.runs)
            if old != new {
                let ns = after as NSString
                let context = ns.substring(with: ns.lineRange(for: NSRange(location: index, length: 0)))
                XCTFail(
                    "\(label): style at \(index) changed (\(old) -> \(new)) outside changedRanges "
                    + "\(ranges) — line: \(context.debugDescription)",
                    file: file, line: line
                )
                break
            }
        }
        return incremental.runs
    }

    // MARK: - What the grammar calls a fence (item 3)

    /// CommonMark: a fence that is never closed runs to the end of the
    /// document. The regex required a closing fence and highlighted nothing.
    func testUnclosedFenceAtEndOfFileIsHighlighted() {
        let text = "# Title\n\n```swift\nlet value = 1\n"
        XCTAssertEqual(style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle)
    }

    /// `~~~` is a fence too. The regex only knew backticks.
    func testTildeFenceIsHighlighted() {
        let text = "# Title\n\n~~~swift\nlet value = 1\n~~~\n"
        XCTAssertEqual(style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle)
    }

    /// An opener may be indented up to three spaces. The regex anchored at
    /// column 0 and skipped these.
    func testFenceIndentedUpToThreeSpacesIsHighlighted() {
        for indent in ["", " ", "  ", "   "] {
            let text = "# Title\n\n\(indent)```swift\n\(indent)let value = 1\n\(indent)```\n"
            XCTAssertEqual(
                style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle,
                "a fence indented by \(indent.count) spaces should still inject"
            )
        }
    }

    /// Four spaces is an indented code block, not a fence — nothing injects.
    func testFenceIndentedFourSpacesIsNotAFence() {
        let text = "# Title\n\n    ```swift\n    let value = 1\n    ```\n"
        XCTAssertNotEqual(style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle)
    }

    /// The info string carries the language plus whatever else the author
    /// wrote. The regex demanded the rest of the line be blank.
    func testInfoStringWithAttributesStillNamesTheLanguage() {
        let text = "# Title\n\n```swift title=\"example.swift\"\nlet value = 1\n```\n"
        XCTAssertEqual(style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle)
    }

    /// An untagged fence injects nothing, and tagging it injects — the same
    /// pair the old regex path was written for.
    func testUntaggedFenceInjectsNothingAndTaggingItInjects() {
        let untagged = "```\nlet value = 1\n```\n"
        let tagged = "```swift\nlet value = 1\n```\n"
        XCTAssertNotEqual(style(of: untagged, at: offset(of: "let value", in: untagged)), swiftLetStyle)
        XCTAssertEqual(style(of: tagged, at: offset(of: "let value", in: tagged)), swiftLetStyle)
    }

    /// A fence nested in a list item. The regex could not match an indented
    /// opener at all.
    func testFenceInsideListItemIsHighlighted() {
        let text = "- item one\n\n  ```swift\n  let value = 1\n  ```\n\n- item two\n"
        XCTAssertEqual(style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle)
    }

    /// A fence nested in a block quote. The `>` markers travel inside
    /// `code_fence_content`, so the injected parser sees them — this pins what
    /// actually happens rather than what one might hope for.
    func testFenceInsideBlockQuoteIsHighlighted() {
        let text = "> intro\n>\n> ```swift\n> let value = 1\n> ```\n"
        XCTAssertEqual(style(of: text, at: offset(of: "let value", in: text)), swiftLetStyle)
    }

    /// An empty fence has no `code_fence_content` child at all.
    func testEmptyFenceDoesNotCrash() {
        let text = "# Title\n\n```swift\n```\n\ntrailing\n"
        XCTAssertFalse(runs(text).isEmpty)
    }

    // MARK: - The inline grammar

    /// `TreeSitterMarkdownInline` ships in the same SPM product the app already
    /// links, so the block grammar's `inline` nodes get a second injected pass —
    /// the one that finds emphasis, strong, code spans and links. Before this
    /// they were unstyled, and so were headings and link destinations: the
    /// palette had no `text.*` scopes but `text.literal`, so every capture the
    /// markdown grammars actually emit resolved to "no style".
    func testInlineGrammarStylesEmphasisStrongCodeAndLinks() {
        let text = "# Title\n\nSome *emphasis*, some **strong**, a `code span` and a [label](https://example.com).\n"
        let cases: [(needle: String, capture: String)] = [
            ("emphasis", "text.emphasis"),
            ("strong", "text.strong"),
            ("code span", "text.literal"),
            ("label", "text.reference"),
            ("https://example.com", "text.uri"),
            ("Title", "text.title")
        ]
        for (needle, capture) in cases {
            let expected = HighlightStyleTable.styleID(forCapture: capture)
            XCTAssertNotEqual(expected, HighlightStyleTable.none, "\(capture) must be in the palette")
            XCTAssertEqual(
                style(of: text, at: offset(of: needle, in: text)), expected,
                "\(needle.debugDescription) should be styled as \(capture)"
            )
        }
    }

    /// An `inline` node spans a whole paragraph, so opening an emphasis on its
    /// first line restyles the second — the same shape as a fence body, and
    /// covered by the same widening rule.
    func testOpeningEmphasisRestylesTheRestOfTheParagraph() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let before = "# Title\n\nfirst line of the paragraph\nsecond line of it* and more\n\ntrailing\n"
        let after  = "# Title\n\nfirst *ine of the paragraph\nsecond line of it* and more\n\ntrailing\n"
        XCTAssertEqual((before as NSString).length, (after as NSString).length)
        let first = runs(before, documentID: id)
        let second = assertContract(
            documentID: id, previous: first, before: before, after: after, label: "openEmphasis"
        )
        let secondLine = offset(of: "second line", in: after)
        XCTAssertEqual(HighlightRunList.style(at: secondLine, in: first), HighlightStyleTable.none)
        XCTAssertEqual(
            HighlightRunList.style(at: secondLine, in: second),
            HighlightStyleTable.styleID(forCapture: "text.emphasis"),
            "the second line of the paragraph should now be inside the emphasis"
        )
    }

    // MARK: - The changed-ranges contract (item 2)

    func testOpeningAFenceMidDocumentReportsTheWholeTail() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let before = "# Title\n\nprose one\n\n``\n\nlet value = 1\n\nprose two\n"
        let after = "# Title\n\nprose one\n\n```swift\n\nlet value = 1\n\nprose two\n"
        let first = runs(before, documentID: id)
        assertContract(documentID: id, previous: first, before: before, after: after, label: "openFence")
    }

    func testClosingAFenceReportsTheTailThatStoppedBeingCode() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let before = "# Title\n\n```swift\nlet value = 1\n\nprose that is inside the fence\n"
        let after = "# Title\n\n```swift\nlet value = 1\n```\nprose that is inside the fence\n"
        let first = runs(before, documentID: id)
        assertContract(documentID: id, previous: first, before: before, after: after, label: "closeFence")
    }

    func testDeletingTheOpeningFenceReportsTheBodyThatStoppedBeingCode() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let before = "# Title\n\n```swift\nlet value = 1\nlet other = 2\n```\n\ntrailing\n"
        let after = "# Title\n\nlet value = 1\nlet other = 2\n```\n\ntrailing\n"
        let first = runs(before, documentID: id)
        assertContract(documentID: id, previous: first, before: before, after: after, label: "deleteOpener")
    }

    func testChangingTheInfoStringReportsTheWholeBody() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let before = "# Title\n\n```swift\n{ \"key\": [1, 2] }\n```\n\ntrailing\n"
        let after = "# Title\n\n```json\n{ \"key\": [1, 2] }\n```\n\ntrailing\n"
        let first = runs(before, documentID: id)
        let second = assertContract(
            documentID: id, previous: first, before: before, after: after, label: "swiftToJson"
        )
        // And it really did recolour: the body is JSON now.
        let key = offset(of: "\"key\"", in: after)
        XCTAssertNotEqual(
            HighlightRunList.style(at: key, in: first),
            HighlightRunList.style(at: key, in: second),
            "retagging swift -> json should recolour the body"
        )
    }

    func testTypingInsideAFenceReportsTheWholeFence() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        // Turning `//` into `/*` on the first body line puts every later line of
        // the fence inside a block comment. The markdown tree cannot report
        // that: to it the whole body is one opaque token, and the edit is one
        // character on the body's first line. Without the fence widening the
        // reported range stops short of the last body line and the incremental
        // run list keeps a stale keyword there — measured, not argued.
        //
        // Both texts are the same length, so an offset means the same character
        // in each and the comparison below is not accidentally comparing a
        // newline against a keyword.
        let before = "# T\n\n```swift\n// note\nlet other = 2\nlet third = 3 */\n```\n\ntrailing\n"
        let after  = "# T\n\n```swift\n/* note\nlet other = 2\nlet third = 3 */\n```\n\ntrailing\n"
        XCTAssertEqual((before as NSString).length, (after as NSString).length)
        let first = runs(before, documentID: id)
        let second = assertContract(
            documentID: id, previous: first, before: before, after: after, label: "typeInFence"
        )
        // The last body line really did change colour, so the assertion above
        // is not vacuous.
        let third = offset(of: "let third", in: after)
        XCTAssertEqual(HighlightRunList.style(at: third, in: first), swiftLetStyle)
        XCTAssertNotEqual(
            HighlightRunList.style(at: third, in: second), swiftLetStyle,
            "opening a block comment should recolour the rest of the fence body"
        )
    }

    /// The point of the whole change: a keystroke in prose must cost a
    /// paragraph, not a document. Needs a document big enough for the
    /// difference to be visible — on a five-line fixture the paragraph
    /// widening alone covers everything.
    func testTypingInProseBetweenFencesDoesNotRepaintTheDocument() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }

        var lines: [String] = ["# Title", ""]
        for section in 0..<20 {
            lines += [
                "## Section \(section)", "",
                "Paragraph \(section) of prose, long enough to be worth repainting on its own.", "",
                "```swift", "let value\(section) = \(section)", "```", ""
            ]
        }
        lines.insert("Anchor prose line, edited below.", at: 2 + 20 / 2 * 8)
        lines.insert("", at: 3 + 20 / 2 * 8)
        let before = lines.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "edited below", with: "edited BELOW")

        let first = runs(before, documentID: id)
        assertContract(documentID: id, previous: first, before: before, after: after, label: "proseEdit")

        guard let result = SyntaxEngine.shared.runsImmediately(
            text: after, language: "markdown", documentID: id
        ) else { return XCTFail("markdown highlighter returned nil") }
        // The pass above already moved the session to `after`; ask again with a
        // one-character edit so this measurement is of a settled session.
        let nudged = after.replacingOccurrences(of: "edited BELOW", with: "edited BELOWW")
        guard let nudge = SyntaxEngine.shared.runsImmediately(
            text: nudged, language: "markdown", documentID: id
        ) else { return XCTFail("markdown highlighter returned nil") }
        _ = result

        guard let ranges = nudge.changedRanges else {
            return XCTFail("a prose edit between fences must report ranges, not a full repaint")
        }
        let total = ranges.reduce(0) { $0 + $1.length }
        let length = (nudged as NSString).length
        XCTAssertLessThan(
            total, length / 8,
            "a prose edit repainted \(total) of \(length) characters: \(ranges)"
        )
    }

    // MARK: - Scripted edits, LF and CRLF (item 5)

    /// 200 lines, three fences, ten single edits applied in sequence through
    /// one session. Every step is checked against a clean parse.
    private func scriptedDocument() -> [String] {
        var lines: [String] = ["# Scripted document", ""]
        for section in 0..<20 {
            lines.append("## Section \(section)")
            lines.append("")
            lines.append("Paragraph \(section) with *emphasis* and `inline code`.")
            lines.append("")
            if section % 7 == 3 {
                lines.append("```swift")
                lines.append("let value\(section) = \(section)")
                lines.append("func make\(section)() -> Int { return \(section) }")
                lines.append("```")
            } else {
                lines.append("- bullet \(section)a")
                lines.append("- bullet \(section)b")
                lines.append("")
                lines.append("More prose for section \(section).")
            }
            lines.append("")
        }
        return lines
    }

    private func scriptedSteps(newline: String) -> [String] {
        let lines = scriptedDocument()
        let base = lines.joined(separator: newline) + newline
        var steps: [String] = [base]

        func mutate(_ transform: (inout [String]) -> Void) {
            var copy = lines
            transform(&copy)
            steps.append(copy.joined(separator: newline) + newline)
        }

        // 1 type in prose
        mutate { $0[4] += "!" }
        // 2 type inside a fence body
        mutate { lines in
            lines[4] += "!"
            if let index = lines.firstIndex(where: { $0.hasPrefix("let value3 ") }) {
                lines[index] = "let value3 = 30"
            }
        }
        // 3 retag a fence
        mutate { lines in
            lines[4] += "!"
            if let index = lines.firstIndex(of: "```swift") { lines[index] = "```json" }
        }
        // 4 delete a fence opener
        mutate { lines in
            lines[4] += "!"
            if let index = lines.firstIndex(of: "```swift") { lines.remove(at: index) }
        }
        // 5 open a new fence in prose
        mutate { lines in
            lines[4] += "!"
            lines[6] = "```swift"
        }
        // 6 and close it again
        mutate { lines in
            lines[4] += "!"
            lines[6] = "```swift"
            lines[8] = "```"
        }
        // 7 add a line inside a fence
        mutate { lines in
            lines[4] += "!"
            if let index = lines.firstIndex(of: "```swift") {
                lines.insert("let extra = 99", at: index + 1)
            }
        }
        // 8 delete a heading
        mutate { lines in
            lines[4] += "!"
            lines.remove(at: 2)
        }
        // 9 paste three lines
        mutate { lines in
            lines[4] += "!"
            lines.insert(contentsOf: ["pasted one", "pasted two", "pasted three"], at: 5)
        }
        // 10 back to the original
        steps.append(base)
        return steps
    }

    private func assertScript(newline: String, label: String) {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let steps = scriptedSteps(newline: newline)
        var previous = runs(steps[0], documentID: id)
        for index in 1..<steps.count {
            previous = assertContract(
                documentID: id,
                previous: previous,
                before: steps[index - 1],
                after: steps[index],
                label: "\(label) step \(index)"
            )
        }
    }

    func testScriptedEditsMatchCleanParsesLF() {
        assertScript(newline: "\n", label: "LF")
    }

    func testScriptedEditsMatchCleanParsesCRLF() {
        assertScript(newline: "\r\n", label: "CRLF")
    }

    /// The same document, both line endings, must highlight the same tokens —
    /// the offsets differ, the styles do not.
    func testCRLFAndLFAgreeOnFenceContents() {
        let lf = "# Title\n\n```swift\nlet value = 1\n```\n\ntrailing\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(style(of: lf, at: offset(of: "let value", in: lf)), swiftLetStyle)
        XCTAssertEqual(style(of: crlf, at: offset(of: "let value", in: crlf)), swiftLetStyle)
    }

    // MARK: - Thai (item 5)

    /// Thai is BMP, so one Character is one UTF-16 unit but three UTF-8 bytes —
    /// the parser is fed UTF-16 and the node ranges come back in UTF-16, so a
    /// fence that follows Thai prose must still land on the right characters.
    func testThaiProseBeforeAndInsideAFence() {
        let text = "# หัวข้อ\n\nข้อความภาษาไทยก่อนโค้ด\n\n```swift\nlet ค่า = 1 // หมายเหตุ\n```\n\nท้ายเรื่อง\n"
        let letOffset = offset(of: "let ค่า", in: text)
        XCTAssertEqual(
            style(of: text, at: letOffset), swiftLetStyle,
            "a fence after Thai prose must still inject at the right offset"
        )

        // And the whole contract holds across an edit in the Thai prose.
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let after = text.replacingOccurrences(of: "ก่อนโค้ด", with: "ก่อนโค้ดมาก")
        let first = runs(text, documentID: id)
        assertContract(documentID: id, previous: first, before: text, after: after, label: "thai")
    }

    // MARK: - Markdown now reports changed ranges

    /// The behaviour this whole change is for: markdown is no longer pinned to
    /// "full repaint every keystroke".
    func testMarkdownReportsChangedRangesOnAnIncrementalPass() {
        let id = UUID()
        defer { SyntaxEngine.shared.discardSession(for: id) }
        let before = "# Title\n\nprose one\n\nprose two\n"
        let after = "# Title\n\nprose one!\n\nprose two\n"
        _ = SyntaxEngine.shared.runsImmediately(text: before, language: "markdown", documentID: id)
        guard let second = SyntaxEngine.shared.runsImmediately(
            text: after, language: "markdown", documentID: id
        ) else { return XCTFail("markdown highlighter returned nil") }
        XCTAssertNotNil(
            second.changedRanges,
            "markdown takes the incremental path now; nil means it fell back to a full repaint"
        )
    }
}


