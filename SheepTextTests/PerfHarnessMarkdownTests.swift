//
//  PerfHarnessMarkdownTests.swift
//  Markdown half of the before/after performance harness — the fenced-code
//  pass moving from a document-wide regex to the tree.
//
//  Deliberately written against the API that already exists on the pre-fix
//  commit — `highlightImmediately(text:language:isDark:documentID:)` and
//  nothing else — so the orchestrator can run this class on both sides of the
//  fix and diff the medians.
//
//  Before the fix every markdown keystroke was a full rebuild, so
//  `syntax_markdown_keystroke_50k` and `syntax_markdown_full_50k` measure the
//  same work on the pre-fix commit. That is the point of running both.
//
//  Each workload prints one `PERF {...}` JSON line. Checksums must match across
//  runs: a faster number with a different checksum is a behaviour change, not
//  an optimisation. Every "keystroke" workload replaces a single character at a
//  fixed offset, so the document length — and therefore the checksum — is
//  constant across iterations.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessMarkdownTests: XCTestCase {

    // MARK: - Fixtures

    /// A markdown document of roughly `chars` UTF-16 units: headings, prose
    /// with inline markup, and one tagged Swift fence per section, so the
    /// injected-language pass has real work to do.
    ///
    /// Two anchors are planted in the middle section:
    /// * `probe 0` — the character a prose keystroke replaces.
    /// * a line reading ``` ``a ``` — replacing its third character with a
    ///   backtick opens a fence, which is the edit that retints the tail.
    private func markdownSource(chars: Int) -> String {
        var out: [String] = ["# Perf document", ""]
        var length = 0
        var section = 0
        // Two passes: the first counts, the second plants the anchors halfway.
        var bodies: [[String]] = []
        while length < chars {
            let body = [
                "## Section \(section)",
                "",
                "Paragraph \(section) with *emphasis*, `inline code` and a [link](https://example.com/\(section)).",
                "More prose for section \(section) so the paragraph is not a single short line.",
                "",
                "```swift",
                "func value\(section)(_ input: Int) -> Int { let result = input * \(section % 7 + 1); return result }",
                "let name\(section) = \"label-\(String(format: "%05d", section))\"",
                "```",
                ""
            ]
            bodies.append(body)
            length += body.reduce(0) { $0 + ($1 as NSString).length + 1 }
            section += 1
        }
        let anchorSection = bodies.count / 2
        for index in bodies.indices {
            out.append(contentsOf: bodies[index])
            if index == anchorSection {
                out.append("Anchor prose line with probe 0 inside it.")
                out.append("")
                out.append("``a")
                out.append("")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// Ten equal-length variants of `base`, differing only in the single
    /// character at `offset`. Precomputed so the measured body does no string
    /// building of its own.
    private func keystrokeVariants(of base: String, at offset: Int, characters: [Character]) -> [String] {
        characters.map { character -> String in
            let mutable = NSMutableString(string: base)
            mutable.replaceCharacters(in: NSRange(location: offset, length: 1), with: String(character))
            return mutable as String
        }
    }

    // MARK: - Full (non-incremental) pass

    func testPerfSyntaxMarkdownFull50k() {
        let text = markdownSource(chars: 50_000)
        PerfHarness.measure("syntax_markdown_full_50k", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "markdown", isDark: true)?.length ?? -1
        }
    }

    // MARK: - Keystroke (incremental) passes

    /// One character typed in prose, between two fences: the edit no fence can
    /// see, and therefore the one that should cost a paragraph and not a
    /// document.
    func testPerfSyntaxMarkdownKeystroke50k() {
        let base = markdownSource(chars: 50_000)
        let ns = base as NSString
        let anchor = ns.range(of: "probe 0")
        let offset = anchor.location == NSNotFound ? ns.length / 2 : anchor.location + 6
        let variants = keystrokeVariants(of: base, at: offset, characters: Array("0123456789"))
        let id = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(
            text: base, language: "markdown", isDark: true, documentID: id
        )
        var counter = 0
        PerfHarness.measure("syntax_markdown_keystroke_50k", samples: 11) {
            counter += 1
            return SyntaxEngine.shared.highlightImmediately(
                text: variants[counter % variants.count],
                language: "markdown", isDark: true, documentID: id
            )?.length ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    /// The third backtick that turns ``` ``a ``` into a fence opener, and the
    /// keystroke that takes it away again — alternating, so every measured call
    /// is the expensive shape. Both variants are the same length, so the
    /// checksum stays constant.
    func testPerfSyntaxMarkdownFenceOpen50k() {
        let base = markdownSource(chars: 50_000)
        let ns = base as NSString
        let anchor = ns.range(of: "\n``a\n")
        let offset = anchor.location == NSNotFound ? ns.length / 2 : anchor.location + 3
        let variants = keystrokeVariants(of: base, at: offset, characters: ["`", "a"])
        let id = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(
            text: base, language: "markdown", isDark: true, documentID: id
        )
        var counter = 0
        PerfHarness.measure("syntax_markdown_fence_open_50k", samples: 11) {
            counter += 1
            return SyntaxEngine.shared.highlightImmediately(
                text: variants[counter % variants.count],
                language: "markdown", isDark: true, documentID: id
            )?.length ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }
}

