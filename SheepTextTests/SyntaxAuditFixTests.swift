//
//  SyntaxAuditFixTests.swift
//  Regression tests for the syntax-engine findings of the 2026-09 audit.
//
//  S1  changedRanges missed the second half of a split line
//  S2  markdown returned changedRanges although its repaint is document-wide
//  S6  cisco_ios / aruba_cx re-highlighted the whole document per keystroke
//  S11 injections were re-parsed once per changed range
//  S12 failed grammar lookups were retried on every keystroke
//
//  The centrepiece is `testChangedRangesCoverEveryAttributeDifference`. All of
//  S1 and S2 are one broken contract — "the previous result and this one differ
//  only inside these ranges" — and the caller in EditorView relies on it
//  absolutely, so it is worth testing as an invariant over several languages and
//  several edit shapes rather than as two special cases.
//

import AppKit
import XCTest
@testable import SheepText

// The engine's test seams (highlightImmediatelyWithRanges, lookup counters)
// exist only in DEBUG builds; the Release test target runs the perf harness only.
#if DEBUG

@MainActor
final class SyntaxAuditFixTests: XCTestCase {

    // MARK: - Helpers

    /// Common prefix/suffix of two strings in UTF-16 units — the same split the
    /// engine makes, so the test can reproduce the splice the engine performed
    /// on the previous pass's attributes.
    ///
    /// The engine additionally refuses to cut a surrogate pair; every fixture
    /// here is BMP-only, so the plain form agrees with it.
    private func affixes(_ old: NSString, _ new: NSString) -> (prefix: Int, suffix: Int) {
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        return (prefix, suffix)
    }

    /// `prior` with the edit that turned `before` into `after` spliced in — what
    /// `EditorView.Coordinator.applySyntaxResult` is holding when the next
    /// result arrives with a `changedRanges` list.
    private func spliced(
        _ prior: NSAttributedString, from before: String, to after: String
    ) -> NSMutableAttributedString {
        let old = before as NSString
        let new = after as NSString
        let (prefix, suffix) = affixes(old, new)
        let result = NSMutableAttributedString(attributedString: prior)
        result.replaceCharacters(
            in: NSRange(location: prefix, length: old.length - suffix - prefix),
            with: new.substring(with: NSRange(location: prefix, length: new.length - suffix - prefix))
        )
        return result
    }

    /// The complement of `ranges` within `0..<length`.
    private func complement(of ranges: [NSRange], length: Int) -> [NSRange] {
        var gaps: [NSRange] = []
        var cursor = 0
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if range.location > cursor {
                gaps.append(NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < length { gaps.append(NSRange(location: cursor, length: length - cursor)) }
        return gaps
    }

    /// The contract itself: outside the reported ranges, the spliced previous
    /// result and the new result must be attribute-for-attribute identical.
    private func assertChangedRangesCoverEveryDifference(
        language: String,
        before: String,
        after: String,
        shape: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let documentID = UUID()
        defer { SyntaxEngine.shared.discardSession(for: documentID) }

        guard let first = SyntaxEngine.shared.highlightImmediatelyWithRanges(
            text: before, language: language, isDark: true, documentID: documentID
        ) else { return XCTFail("\(language)/\(shape): first pass returned nil", file: file, line: line) }

        guard let second = SyntaxEngine.shared.highlightImmediatelyWithRanges(
            text: after, language: language, isDark: true, documentID: documentID
        ) else { return XCTFail("\(language)/\(shape): second pass returned nil", file: file, line: line) }

        // nil means "full repaint required" — the caller repaints everything,
        // so there is nothing to check.
        guard let ranges = second.changedRanges else { return }

        let base = spliced(first.value, from: before, to: after)
        XCTAssertEqual(
            base.length, second.value.length,
            "\(language)/\(shape): splice produced a different length",
            file: file, line: line
        )
        guard base.length == second.value.length else { return }

        for gap in complement(of: ranges, length: second.value.length) where gap.length > 0 {
            guard !base.attributedSubstring(from: gap).isEqual(second.value.attributedSubstring(from: gap)) else {
                continue
            }
            // Narrow down to the first offending character so the failure names it.
            var offender = gap.location
            for index in gap.location..<NSMaxRange(gap) {
                let unit = NSRange(location: index, length: 1)
                if !base.attributedSubstring(from: unit).isEqual(second.value.attributedSubstring(from: unit)) {
                    offender = index
                    break
                }
            }
            let ns = after as NSString
            let context = ns.substring(with: ns.lineRange(for: NSRange(location: offender, length: 0)))
            XCTFail(
                """
                \(language)/\(shape): attributes differ at \(offender), which is OUTSIDE the \
                reported changedRanges \(ranges.map { "\($0.location)+\($0.length)" }).
                Line: \(context.debugDescription)
                """,
                file: file, line: line
            )
            return
        }
    }

    // MARK: - Fixtures

    private func ciscoLines() -> [String] {
        var lines: [String] = []
        for i in 0..<60 {
            lines.append("interface GigabitEthernet1/0/\(i % 24 + 1)")
            lines.append(" switchport access vlan \(i % 4000 + 1)")
            lines.append(" switchport trunk allowed vlan 10 20")
            lines.append(" spanning-tree mode rapid-pvst")
            lines.append("!")
        }
        return lines
    }

    private func arubaLines() -> [String] {
        var lines: [String] = []
        for i in 0..<60 {
            lines.append("interface 1/1/\(i % 24 + 1)")
            lines.append("    description uplink-\(i)")
            lines.append("    ip address 10.0.\(i % 250).1/24")
            lines.append("    vlan trunk allowed 10,20-30")
            lines.append("    state connected up")
            lines.append("! section \(i)")
        }
        return lines
    }

    private func swiftLines() -> [String] {
        var lines: [String] = []
        for i in 0..<50 {
            lines.append("func value\(i)(_ input: Int) -> Int {")
            lines.append("    let result = input * \(i + 2) // note \(i)")
            lines.append("    return result")
            lines.append("}")
        }
        return lines
    }

    private func jsonLines() -> [String] {
        var lines: [String] = ["{"]
        for i in 0..<60 {
            lines.append("  \"key\(i)\": { \"n\": \(i), \"s\": \"value \(i)\", \"b\": true },")
        }
        lines.append("  \"last\": null")
        lines.append("}")
        return lines
    }

    private func markdownLines() -> [String] {
        var lines: [String] = ["# Title", ""]
        for i in 0..<25 {
            lines.append("## Section \(i)")
            lines.append("")
            lines.append("Some *emphasis* and `code` in paragraph \(i).")
            lines.append("")
            lines.append("```swift")
            lines.append("let value\(i) = \(i)")
            lines.append("```")
            lines.append("")
        }
        return lines
    }

    /// The five edit shapes the audit calls out, as (name, before, after) pairs
    /// built from one line array.
    private func editShapes(_ lines: [String]) -> [(shape: String, before: String, after: String)] {
        let base = lines.joined(separator: "\n") + "\n"
        // The pivot has to be a line worth editing: long enough to split at an
        // interior space, and not the last line (the join shape needs a
        // successor). Markdown's fixture is half blank lines, so "count / 2" on
        // its own picks an empty string.
        let pivot = (lines.count / 2..<lines.count - 1).first { index in
            let line = lines[index] as NSString
            guard line.length > 2 else { return false }
            return line.range(
                of: " ", options: [], range: NSRange(location: 1, length: line.length - 2)
            ).location != NSNotFound
        } ?? (lines.count / 2)
        var shapes: [(String, String, String)] = []

        // Type a character inside a line.
        var typed = lines
        typed[pivot] = typed[pivot] + "9"
        shapes.append(("typeInsideLine", base, typed.joined(separator: "\n") + "\n"))

        // Split a line at a space — the S1 case.
        var split = lines
        let target = split[pivot] as NSString
        let space = target.length > 2
            ? target.range(of: " ", options: [], range: NSRange(location: 1, length: target.length - 2))
            : NSRange(location: NSNotFound, length: 0)
        if space.location != NSNotFound {
            split[pivot] = target.substring(to: space.location) + "\n" + target.substring(from: space.location)
            shapes.append(("splitLine", base, split.joined(separator: "\n") + "\n"))
        }

        // Join two lines.
        var joined = lines
        joined[pivot] = joined[pivot] + joined[pivot + 1]
        joined.remove(at: pivot + 1)
        shapes.append(("joinLines", base, joined.joined(separator: "\n") + "\n"))

        // Paste three lines.
        var pasted = lines
        pasted.insert(contentsOf: [lines[pivot], lines[pivot + 1], lines[pivot]], at: pivot)
        shapes.append(("pasteThreeLines", base, pasted.joined(separator: "\n") + "\n"))

        // Delete a line.
        var deleted = lines
        deleted.remove(at: pivot)
        shapes.append(("deleteLine", base, deleted.joined(separator: "\n") + "\n"))

        return shapes.map { (shape: $0.0, before: $0.1, after: $0.2) }
    }

    // MARK: - S1

    /// The exact break the audit reproduced: `vlan 10 20` colours `20` as a
    /// number, and pressing Return before ` 20` makes it the first token of its
    /// own line — which the Cisco highlighter colours as a keyword. The edit's
    /// `newRange` is the terminator, and `lineRange(for:)` of a terminator
    /// returns only the line it closes, so `20`'s new line was never in
    /// `changedRanges` and the screen kept the stale orange.
    func testSplitLineChangedRangesIncludeTheTailThatBecameANewLine() {
        let documentID = UUID()
        defer { SyntaxEngine.shared.discardSession(for: documentID) }

        let before = String(repeating: "vlan 10 20\nvlan 30 40\n", count: 40)
        let after = before.replacingOccurrences(
            of: "vlan 10 20",
            with: "vlan 10\n 20",
            options: [],
            range: before.range(of: "vlan 10 20")
        )

        _ = SyntaxEngine.shared.highlightImmediatelyWithRanges(
            text: before, language: "cisco_ios", isDark: true, documentID: documentID
        )
        guard let second = SyntaxEngine.shared.highlightImmediatelyWithRanges(
            text: after, language: "cisco_ios", isDark: true, documentID: documentID
        ) else { return XCTFail("cisco highlighter returned nil") }
        guard let ranges = second.changedRanges else {
            return XCTFail("cisco_ios must report changed ranges on an incremental pass")
        }

        let ns = after as NSString
        let tail = ns.range(of: "\n 20\n")
        XCTAssertNotEqual(tail.location, NSNotFound)
        let twenty = tail.location + 2

        XCTAssertTrue(
            ranges.contains { NSLocationInRange(twenty, $0) },
            "the tail that became its own line is not inside changedRanges \(ranges)"
        )

        // And it really did change colour: keyword, not number.
        let keyword = second.value.attribute(.foregroundColor, at: twenty, effectiveRange: nil) as? NSColor
        let stillANumber = ns.range(of: "vlan 30 40")
        let number = second.value.attribute(
            .foregroundColor, at: stillANumber.location + 8, effectiveRange: nil
        ) as? NSColor
        XCTAssertNotNil(keyword)
        XCTAssertNotNil(number)
        XCTAssertNotEqual(keyword, number, "the split tail should now be a keyword, not a number")
    }

    // MARK: - S1 + S2 as one invariant

    func testChangedRangesCoverEveryAttributeDifference() {
        let corpus: [(String, [String])] = [
            ("cisco_ios", ciscoLines()),
            ("aruba_cx", arubaLines()),
            ("swift", swiftLines()),
            ("markdown", markdownLines()),
            ("json", jsonLines()),
        ]
        for (language, lines) in corpus {
            for shape in editShapes(lines) {
                assertChangedRangesCoverEveryDifference(
                    language: language, before: shape.before, after: shape.after, shape: shape.shape
                )
            }
        }
    }

    // MARK: - S2

    /// The repro shape from the audit: tagging a previously untagged fence makes
    /// the fence pass recolour the body. The block grammar's changed ranges
    /// cover only the info string, so the engine widens them to the fence it
    /// overlaps (`markdownInjectionScan`) — a caller applying only the reported
    /// ranges used to drop the body. Until September 2026 this asserted
    /// `changedRanges == nil` (markdown was a full rebuild); now it asserts the
    /// ranges actually cover the body.
    func testTaggingAFenceRecoloursItsBody() throws {
        let documentID = UUID()
        defer { SyntaxEngine.shared.discardSession(for: documentID) }

        let untagged = "# Title\n\n```\nlet x = 1\n```\n\ntrailing\n"
        let tagged = "# Title\n\n```swift\nlet x = 1\n```\n\ntrailing\n"

        guard let first = SyntaxEngine.shared.highlightImmediatelyWithRanges(
            text: untagged, language: "markdown", isDark: true, documentID: documentID
        ), let second = SyntaxEngine.shared.highlightImmediatelyWithRanges(
            text: tagged, language: "markdown", isDark: true, documentID: documentID
        ) else { return XCTFail("markdown highlighter returned nil") }

        let bodyBefore = (untagged as NSString).range(of: "let x")
        let bodyAfter = (tagged as NSString).range(of: "let x")
        let colourBefore = first.value.attribute(.foregroundColor, at: bodyBefore.location, effectiveRange: nil) as? NSColor
        let colourAfter = second.value.attribute(.foregroundColor, at: bodyAfter.location, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(
            colourBefore, colourAfter,
            "tagging the fence should make the body highlight as Swift"
        )
        let reported = try XCTUnwrap(second.changedRanges, "markdown now reports ranges")
        XCTAssertTrue(
            reported.contains { NSIntersectionRange($0, bodyAfter).length == bodyAfter.length },
            "the changed ranges must cover the fence body that changed colour: \(reported)"
        )
    }

    // MARK: - S6

    /// The proof that the regex highlighters are line-local: ten random
    /// single-character edits on a 5000-line config, each incremental result
    /// compared against a clean rebuild of the same text.
    private func assertIncrementalMatchesCleanUnderRandomEdits(
        language: String,
        lines: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let documentID = UUID()
        defer { SyntaxEngine.shared.discardSession(for: documentID) }

        var text = lines.joined(separator: "\n") + "\n"
        XCTAssertNotNil(
            SyntaxEngine.shared.highlightImmediately(
                text: text, language: language, isDark: true, documentID: documentID
            ),
            file: file, line: line
        )

        var generator = SystemRandomNumberGenerator()
        let replacements = Array("0123456789abcdef-. ,/!")
        for step in 0..<10 {
            let ns = text as NSString
            let offset = Int.random(in: 0..<ns.length, using: &generator)
            let mutable = NSMutableString(string: text)
            // Never overwrite a line terminator: that is a different edit shape
            // (covered by `editShapes`) and it would make the fixture drift.
            let unit = ns.character(at: offset)
            let replacement = (unit == 0x0A || unit == 0x0D)
                ? String(replacements.randomElement(using: &generator)!) + "\n"
                : String(replacements.randomElement(using: &generator)!)
            mutable.replaceCharacters(in: NSRange(location: offset, length: 1), with: replacement)
            text = mutable as String

            let incremental = SyntaxEngine.shared.highlightImmediately(
                text: text, language: language, isDark: true, documentID: documentID
            )
            let clean = SyntaxEngine.shared.highlightImmediately(
                text: text, language: language, isDark: true
            )
            XCTAssertNotNil(incremental, "\(language) step \(step)", file: file, line: line)
            XCTAssertNotNil(clean, "\(language) step \(step)", file: file, line: line)
            if let incremental, let clean {
                XCTAssertTrue(
                    incremental.isEqual(to: clean),
                    "\(language): incremental diverged from a clean pass at edit \(step) (offset \(offset))",
                    file: file, line: line
                )
            }
        }
    }

    func testCiscoIncrementalHighlightMatchesCleanPassUnderRandomEdits() {
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("interface GigabitEthernet1/0/\(i % 48 + 1)")
            lines.append(" switchport trunk allowed vlan 10,20,30-40,\(i % 4000 + 1)")
            lines.append(" spanning-tree mode rapid-pvst")
            lines.append(" description port-\(i)")
            lines.append("!")
        }
        assertIncrementalMatchesCleanUnderRandomEdits(language: "cisco_ios", lines: lines)
    }

    func testArubaIncrementalHighlightMatchesCleanPassUnderRandomEdits() {
        var lines: [String] = []
        for i in 0..<1000 {
            lines.append("interface 1/1/\(i % 48 + 1)")
            lines.append("    vlan trunk allowed 10,20-30,\(i % 4000 + 1)")
            lines.append("    ip address 10.\(i % 250).0.1/24")
            lines.append("    mac-address aabb.ccdd.eeff")
            lines.append("    state connected up down warning")
            lines.append("! section \(i)")
        }
        assertIncrementalMatchesCleanUnderRandomEdits(language: "aruba_cx", lines: lines)
    }

    /// The rewritten tokenizer reads through a `CFStringInlineBuffer` instead of
    /// `NSString.character(at:)` and no longer builds a String per token. These
    /// are the classifications the old one made, token for token.
    func testCiscoTokenClassificationIsUnchangedByTheInlineBufferTokenizer() {
        let source = """
        ! header comment
        \tvlan 1,3,23,101-102,306s
        spanning-tree mode rpvsts
        spanning-tree mode rapid-pvst
        interface GigabitEthernet1/0/24
         switchport mode access
         ip address 10.0.0.1 255.255.255.0

        """
        guard let result = SyntaxEngine.shared.highlightImmediately(
            text: source, language: "cisco_ios", isDark: true
        ) else { return XCTFail("cisco highlighter returned nil") }

        let ns = source as NSString
        func colour(_ token: String) -> NSColor? {
            let range = ns.range(of: token)
            guard range.location != NSNotFound else { return nil }
            return result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }

        let comment = colour("! header")
        let keyword = colour("spanning-tree")
        let validVlan = colour("101-102")
        let invalidVlan = colour("306s")
        let invalidMode = colour("rpvsts")
        let validMode = colour("rapid-pvst")
        let number = colour("10.0.0.1")
        let subKeyword = colour("access")

        for value in [comment, keyword, validVlan, invalidVlan, invalidMode, validMode, number, subKeyword] {
            XCTAssertNotNil(value)
        }
        XCTAssertEqual(invalidVlan, invalidMode, "both are the error scope")
        XCTAssertNotEqual(validVlan, invalidVlan)
        XCTAssertNotEqual(validMode, invalidMode)
        XCTAssertEqual(validVlan, number, "both are the number scope")
        XCTAssertEqual(subKeyword, keyword, "sub-keywords take the keyword scope")

        // A tab-indented line is still tokenised, and the comma is punctuation.
        let comma = ns.range(of: ",")
        let commaColour = result.attribute(.foregroundColor, at: comma.location, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(commaColour)
        XCTAssertNotEqual(commaColour, validVlan)
    }

    // MARK: - S11

    /// Injections are now run once over the union of the changed ranges, with
    /// duplicate sites skipped. The pass is idempotent, so equality against a
    /// clean rebuild is the whole proof.
    func testHTMLInjectionsSurviveTheUnionedIncrementalPass() {
        let documentID = UUID()
        defer { SyntaxEngine.shared.discardSession(for: documentID) }

        var script: [String] = []
        for i in 0..<200 {
            script.append("  const value\(i) = compute(\(i), \"label-\(i)\");")
        }
        let head = "<!doctype html>\n<html>\n<head><style>body { color: red; }</style></head>\n<body>\n<script>\n"
        let tail = "\n</script>\n</body>\n</html>\n"
        let steps = [
            head + script.joined(separator: "\n") + tail,
            head + script.joined(separator: "\n").replacingOccurrences(of: "compute(7,", with: "compute(77,") + tail,
            head + (script + ["  return 1;"]).joined(separator: "\n") + tail,
        ]
        for (index, step) in steps.enumerated() {
            let incremental = SyntaxEngine.shared.highlightImmediately(
                text: step, language: "html", isDark: true, documentID: documentID
            )
            let clean = SyntaxEngine.shared.highlightImmediately(
                text: step, language: "html", isDark: true
            )
            XCTAssertNotNil(incremental, "step \(index)")
            XCTAssertNotNil(clean, "step \(index)")
            if let incremental, let clean {
                XCTAssertTrue(incremental.isEqual(to: clean), "html injections diverged at step \(index)")
            }
        }
    }

    // MARK: - S12

    /// A language whose grammar cannot be configured used to re-walk
    /// `Bundle.allBundles + allFrameworks`, stat two override paths and
    /// re-attempt the query compile on every single highlight pass.
    func testFailedConfigurationLookupIsRememberedInsteadOfRetried() {
        let language = "sheeptext-audit-no-such-grammar"
        let before = SyntaxEngine.configurationLookupAttempts
        XCTAssertFalse(SyntaxEngine.shared.lookUpConfigurationForTesting(language))
        let afterFirst = SyntaxEngine.configurationLookupAttempts
        XCTAssertEqual(afterFirst, before + 1, "the first lookup should do the work")

        for _ in 0..<5 {
            XCTAssertFalse(SyntaxEngine.shared.lookUpConfigurationForTesting(language))
        }
        XCTAssertEqual(
            SyntaxEngine.configurationLookupAttempts, afterFirst,
            "a remembered failure must not re-walk the bundles"
        )

        // A language that does configure is cached the same way.
        XCTAssertTrue(SyntaxEngine.shared.lookUpConfigurationForTesting("swift"))
        let afterSwift = SyntaxEngine.configurationLookupAttempts
        XCTAssertTrue(SyntaxEngine.shared.lookUpConfigurationForTesting("swift"))
        XCTAssertEqual(SyntaxEngine.configurationLookupAttempts, afterSwift)
    }
}
#endif
