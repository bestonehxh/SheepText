import XCTest
@testable import SheepSyntaxKit
import NetworkHighlightKit

/// The design's one promise: an incremental pass is EXACTLY a clean pass.
/// Random edits — biased towards the characters that open and close
/// multi-line constructs — are applied through one session and compared,
/// run for run, against a fresh highlighter over the same text.
final class IncrementalTests: XCTestCase {
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
    }

    private static let snippets: [String] = [
        "\n", "\n", "\n", "\r\n", "\r", " ", "  ", "\t", "x", "foo", "1", "\"", "'", "`", "\"\"\"", "'''",
        "/*", "*/", "//", "#", "--", "{-", "-}", "{", "}", "(", ")", "[", "]", "<", ">", "</", "/>", "<!--",
        "-->", "${", "#{", "$(", "\\", "\\(", "```", "```swift\n", "~~~", "---\n", "===\n", "- ", "> ", "* ",
        "**", "_", "<?php", "?>", "<script>", "</script>", "<style>", "<<EOF\n", "EOF\n", "<<<EOT\n",
        "EOT;\n", "=begin\n", "=end\n", "@@ -1,2 +1,3 @@\n", "+", "-", "|", ": ", "key: |\n", "r#\"", "\"#",
        "é", "😀", "ก่", "$$", "%w[", "~r/", "RUN ", "\\\n", "[[", "]]", "@", "=", ";",
    ]

    private func check(_ language: SyntaxGrammar, _ sample: String, seed: UInt64, edits: Int) {
        var rng = RNG(state: seed)
        let session = SyntaxHighlighter(grammar: language)
        var text = Array(sample.utf16)
        var previous = session.update(text).runs
        assertInvariants(previous, text, language)

        for step in 0..<edits {
            let position = rng.below(text.count + 1)
            let deleteCount = min(text.count - position, rng.below(4) == 0 ? rng.below(12) : rng.below(3))
            let snippet = Array(Self.snippets[rng.below(Self.snippets.count)].utf16)
            var edited = text
            edited.replaceSubrange(position..<(position + deleteCount), with: snippet)

            let update = session.update(edited)
            let clean = SyntaxHighlighter(grammar: language).update(edited).runs
            if update.runs != clean {
                let firstDiff = Array(zip(update.runs, clean)).firstIndex { $0 != $1 } ?? min(update.runs.count, clean.count)
                XCTFail("""
                \(language) seed \(seed) step \(step): incremental != clean at run \(firstDiff)
                incremental: \(update.runs[firstDiff..<min(firstDiff + 4, update.runs.count)])
                clean:       \(clean[firstDiff..<min(firstDiff + 4, clean.count)])
                """)
                return
            }
            assertInvariants(clean, edited, language)

            // Outside the changed ranges, the result must be the previous
            // result, shifted across the edit.
            if let ranges = update.changedRanges, let range = ranges.first {
                let delta = edited.count - text.count
                let before = clean.filter { $0.end <= range.lowerBound }
                let beforeOld = previous.filter { $0.end <= range.lowerBound }
                XCTAssertEqual(before, beforeOld, "\(language) step \(step): runs before the changed range moved")
                let after = clean.filter { $0.location >= range.upperBound }
                let afterOld = previous.filter { $0.location >= range.upperBound - delta }
                    .map { SyntaxRun(location: $0.location + delta, length: $0.length, scope: $0.scope) }
                XCTAssertEqual(after, afterOld, "\(language) step \(step): runs after the changed range changed")
            }
            text = edited
            previous = clean
        }
    }

    private func assertInvariants(_ runs: [SyntaxRun], _ text: [UInt16], _ language: SyntaxGrammar) {
        var last = 0
        for run in runs {
            XCTAssertGreaterThan(run.length, 0, "\(language): empty run")
            XCTAssertGreaterThanOrEqual(run.location, last, "\(language): overlapping or unsorted runs")
            XCTAssertLessThanOrEqual(run.end, text.count, "\(language): run past the end")
            XCTAssertNotEqual(run.scope, .none, "\(language): a run with no scope")
            for index in run.location..<run.end where text[index] == 0x0A || text[index] == 0x0D {
                XCTFail("\(language): run crosses a line break at \(index)")
                return
            }
            last = run.end
        }
    }

    func testIncrementalEqualsCleanForEveryLanguage() {
        for (language, sample) in Samples.grammars {
            for seed: UInt64 in [0x9E3779B97F4A7C15, 0xD1B54A32D192ED03, 42] {
                check(language, sample, seed: seed, edits: 250)
            }
        }
    }

    /// `SHEEPSYNTAX_FUZZ=1`: the same property, twenty seeds deep.
    func testDeepFuzz() throws {
        guard ProcessInfo.processInfo.environment["SHEEPSYNTAX_FUZZ"] != nil else { throw XCTSkip("set SHEEPSYNTAX_FUZZ") }
        for (language, sample) in Samples.grammars {
            for seed in 1...20 {
                check(language, sample, seed: UInt64(seed) &* 0x9E3779B97F4A7C15, edits: 400)
            }
        }
    }

    func testTypingASampleCharacterByCharacter() {
        // Every prefix of every sample, typed one unit at a time.
        for (language, sample) in Samples.grammars {
            let units = Array(sample.utf16)
            let session = SyntaxHighlighter(grammar: language)
            var typed: [UInt16] = []
            _ = session.update(typed)
            for unit in units {
                typed.append(unit)
                let incremental = session.update(typed).runs
                let clean = SyntaxHighlighter(grammar: language).update(typed).runs
                if incremental != clean {
                    XCTFail("\(language): typing diverged at \(typed.count)")
                    break
                }
            }
        }
    }

    func testDeletingTheWholeDocumentAndUndoing() {
        for (language, sample) in Samples.grammars {
            let session = SyntaxHighlighter(grammar: language)
            let original = session.update(sample).runs
            XCTAssertEqual(session.update("").runs, [])
            XCTAssertEqual(session.update(sample).runs, original, "\(language)")
        }
    }

    func testNoChangeReportsNoChangedRanges() {
        let session = SyntaxHighlighter(language: .swift)
        XCTAssertNil(session.update(Samples.swift).changedRanges)
        XCTAssertEqual(session.update(Samples.swift).changedRanges?.isEmpty, true)
    }

    func testChangedRangeIsLocalForAnOrdinaryKeystroke() {
        let session = SyntaxHighlighter(language: .swift)
        let big = String(repeating: Samples.swift + "\n", count: 50)
        _ = session.update(big)
        var edited = Array(big.utf16)
        let middle = edited.count / 2
        edited.insert(0x78, at: middle)
        let update = session.update(edited)
        let range = try! XCTUnwrap(update.changedRanges?.first)
        XCTAssertLessThan(range.count, 400, "a keystroke should re-lex a line or two, not \(range.count) units")
    }

    func testOpeningABlockCommentRecolorsToTheEnd() {
        let session = SyntaxHighlighter(language: .swift)
        let source = "let a = 1\nlet b = 2\nlet c = 3\n"
        _ = session.update(source)
        let update = session.update("/*" + source)
        XCTAssertEqual(update.runs.map(\.scope), [.comment, .comment, .comment])
        XCTAssertEqual(update.changedRanges?.first?.upperBound, ("/*" + source).utf16.count)
    }
}

/// Arbitrary input, not realistic input: every grammar must survive random
/// units — lone surrogates, control characters, very long lines — without a
/// trap or a hang, and still agree with a clean pass.
final class GarbageTests: XCTestCase {
    func testRandomUnitsNeverTrapAndStayExact() {
        var state: UInt64 = 0x243F6A8885A308D3
        func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
        let alphabet: [UInt16] = Array("\n\r\t \"'`/*#-<>{}()[]$@\\!?=:;,.|&~%^+_0123456789abcXYZ".utf16)
            + [0x0085, 0x2028, 0x2029, 0xD83D, 0xDE00, 0xDC00, 0x0E01, 0x0E48, 0x00, 0xFEFF, 0x7F]
        for (grammar, _) in Samples.grammars {
            let session = SyntaxHighlighter(grammar: grammar)
            var text: [UInt16] = []
            for step in 0..<300 {
                let position = Int(next() % UInt64(text.count + 1))
                let delete = min(text.count - position, Int(next() % 4))
                let length = next() % 10 == 0 ? Int(next() % 400) : Int(next() % 6)
                let insert = (0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }
                text.replaceSubrange(position..<(position + delete), with: insert)
                let incremental = session.update(text).runs
                let clean = SyntaxHighlighter(grammar: grammar).update(text).runs
                if incremental != clean {
                    XCTFail("\(grammar) step \(step): incremental != clean")
                    break
                }
                for run in clean { XCTAssert(run.end <= text.count && run.length > 0) }
            }
        }
    }
}
