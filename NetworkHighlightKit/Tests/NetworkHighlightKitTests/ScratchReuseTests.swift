import Foundation
import XCTest
@testable import NetworkHighlightKit

/// The scanner's eleven match buckets and eleven cursors used to be allocated
/// inside `scan` — once per CALL, and the caller is per LINE. They now live in a
/// `HighlightScanner.Scratch` that a whole-text pass builds once and `reset()`s
/// between lines.
///
/// Reuse is only correct if a reset really restores what a fresh scan starts
/// from, and the ways it can fail are all silent: a bucket that kept one range
/// from the previous line, a cursor left advanced (which would suppress every
/// later match of that rule), or a span buffer still referenced by the caller
/// (copy-on-write, so it produces a wrong answer rather than a crash). None of
/// those changes a span COUNT reliably — they move spans onto the wrong line.
///
/// So every test here runs the same input through both workspaces and demands
/// identical output. The allocating path is the oracle: `HighlightScanner.scan`
/// still builds fresh buckets and `claim(_:rules:)` still builds a fresh merge,
/// and both are kept precisely so this comparison exists.
final class ScratchReuseTests: XCTestCase {

    /// The shared corpora, plus the two document shapes a corpus of ASCII
    /// one-liners cannot reach.
    private var samples: [String] {
        neutralCorpus + vendorCorpus + [
            // Thai + emoji, mixed with ASCII-only lines in ONE document. The
            // UTF-8 -> UTF-16 mapping runs only for lines carrying a byte
            // >= 0x80, so this is what makes a single shared scratch cross
            // between the mapped and unmapped branches line after line. The
            // emoji matter on their own: a 4-byte lead is a surrogate PAIR, so
            // a stale span here lands at an offset that is wrong by a variable
            // amount rather than a constant one.
            """
            description ห้อง 10.0.0.1 🐑 GigabitEthernet1/0/1 up
            interface Gi1/0/2
             mac-address aabb.ccdd.eeff ห้อง10 🎉 down
             ip address 192.168.1.1 255.255.255.0
             switchport trunk allowed vlan 10,20,30-40
            """,
            // CRLF. The CR is just another byte to the scanner, but it sits at
            // the end of every line, which is exactly where a `\\b` at the end
            // of a match has to look — and it is the byte a reused cursor would
            // be measured against.
            "no shutdown\r\nvlan 10,20,30-40\r\ninterface GigabitEthernet1/0/1\r\n"
                + "10.0.0.1/24 permit tcp any any\r\n00:11:22:33:44:55 err-disabled\r\n"
                + "2001:db8::1 fe80::1/64 up\r\n",
            // Both at once, and a blank line between them: a line the scan skips
            // entirely must not leave the scratch holding the line before it.
            "interface Vlan10 ห้องเซิร์ฟเวอร์ 🐑\r\n\r\n 10.0.0.1 255.255.255.0 up\r\n",
        ]
    }

    // MARK: - The two workspaces

    /// Every non-empty line of `buffer`, in order. Both paths split with this
    /// one, so a difference between them can only come from the workspace.
    private func forEachLine(
        _ buffer: HighlightScanner.Bytes, _ body: (HighlightScanner.Bytes, Int) -> Void
    ) {
        let n = buffer.count
        var lineStart = 0
        while lineStart <= n {
            var i = lineStart
            while i < n, buffer[i] != 0x0A { i += 1 }
            if i > lineStart {
                body(HighlightScanner.Bytes(rebasing: buffer[lineStart..<i]), lineStart)
            }
            if i == n { break }
            lineStart = i + 1
        }
    }

    /// Per-line byte spans through the ALLOCATING path — the oracle.
    private func allocatingLines(_ text: String, _ hl: NetworkHighlighter) -> [String] {
        var copy = text
        return copy.withUTF8 { buffer -> [String] in
            var out: [String] = []
            forEachLine(buffer) { line, _ in
                let perRule = HighlightScanner.scan(
                    line, enabledMask: hl.profile.rules, profile: hl.profile
                )
                out.append(describe(NetworkHighlighter.claim(perRule, rules: hl.rules)))
            }
            return out
        }
    }

    /// Per-line byte spans through ONE scratch, consumed in place — no reference
    /// to `scratch.claimed` outlives the line, which is how the whole-text path
    /// uses it and the case where the buffers really are reused rather than
    /// copy-on-written.
    private func sharedScratchLines(_ text: String, _ hl: NetworkHighlighter) -> [String] {
        var copy = text
        return copy.withUTF8 { buffer -> [String] in
            var out: [String] = []
            let scratch = HighlightScanner.Scratch()
            forEachLine(buffer) { line, _ in
                hl.scanLine(line, into: scratch)
                out.append(describe(scratch.claimed))
            }
            return out
        }
    }

    /// Per-line byte spans through a FRESH scratch each line. Isolates "the
    /// scratch type is right" from "reusing it is right".
    private func freshScratchLines(_ text: String, _ hl: NetworkHighlighter) -> [String] {
        var copy = text
        return copy.withUTF8 { buffer -> [String] in
            var out: [String] = []
            forEachLine(buffer) { line, _ in
                let scratch = HighlightScanner.Scratch()
                hl.scanLine(line, into: scratch)
                out.append(describe(scratch.claimed))
            }
            return out
        }
    }

    /// One shared scratch whose spans are HELD after each line. That leaves a
    /// second reference on the buffer, so the next reset copy-on-writes instead
    /// of reusing — the slow path, which still has to be the correct one.
    private func retainedScratchLines(_ text: String, _ hl: NetworkHighlighter) -> [String] {
        var copy = text
        return copy.withUTF8 { buffer -> [String] in
            var held: [[NetworkSpan]] = []
            let scratch = HighlightScanner.Scratch()
            forEachLine(buffer) { line, _ in
                hl.scanLine(line, into: scratch)
                held.append(scratch.claimed)
            }
            return held.map { describe($0) }
        }
    }

    /// `spans(in:)`'s walk, with a fresh allocating scan per line. The line
    /// splitting and the UTF-8 -> UTF-16 mapping are the package's own code,
    /// reused verbatim, so any difference from `spans(in:)` is the scratch.
    private func allocatingSpans(in text: String, _ hl: NetworkHighlighter) -> [NetworkSpan] {
        var copy = text
        return copy.withUTF8 { buffer -> [NetworkSpan] in
            var out: [NetworkSpan] = []
            var utf16LineStart = 0
            var lineStart = 0
            let n = buffer.count
            while lineStart <= n {
                var i = lineStart
                while i < n, buffer[i] != 0x0A { i += 1 }
                if i > lineStart {
                    let line = HighlightScanner.Bytes(rebasing: buffer[lineStart..<i])
                    let perRule = HighlightScanner.scan(
                        line, enabledMask: hl.profile.rules, profile: hl.profile
                    )
                    let spans = NetworkHighlighter.claim(perRule, rules: hl.rules)
                    // Identity mapping on an ASCII line, so one branch covers both.
                    NetworkHighlighter.appendMapped(
                        spans, of: line, base: utf16LineStart, into: &out
                    )
                    utf16LineStart += NetworkHighlighter.utf16Length(of: line)
                }
                if i == n { break }
                utf16LineStart += 1
                lineStart = i + 1
            }
            return out
        }
    }

    // MARK: - Tests

    /// The headline equivalence: the whole-text scratch path against the
    /// allocating path, for every vendor pack over every sample.
    func testWholeTextScratchPathMatchesAllocatingPathForEveryVendor() {
        for vendor in Vendor.allCases {
            let hl = NetworkHighlighter(vendor: vendor)
            for (i, text) in samples.enumerated() {
                XCTAssertEqual(
                    describe(hl.spans(in: text)),
                    describe(allocatingSpans(in: text, hl)),
                    "[\(vendor.rawValue)] sample#\(i)\ninput: \(text.debugDescription)"
                )
            }
        }
    }

    /// All four workspaces, line by line, for every vendor over every sample.
    func testEveryWorkspaceAgreesLineByLineForEveryVendor() {
        for vendor in Vendor.allCases {
            let hl = NetworkHighlighter(vendor: vendor)
            for (i, text) in samples.enumerated() {
                let oracle = allocatingLines(text, hl)
                let label = "[\(vendor.rawValue)] sample#\(i)\ninput: \(text.debugDescription)"
                XCTAssertEqual(sharedScratchLines(text, hl), oracle, "shared scratch \(label)")
                XCTAssertEqual(freshScratchLines(text, hl), oracle, "fresh scratch \(label)")
                XCTAssertEqual(retainedScratchLines(text, hl), oracle, "retained spans \(label)")
            }
        }
    }

    /// The public `scanLine` overloads allocate their own scratch. They must
    /// still answer what the shared one does — they are what a host that scans
    /// a single line on a keystroke calls.
    func testPublicScanLineMatchesTheSharedScratchForEveryVendor() {
        for vendor in Vendor.allCases {
            let hl = NetworkHighlighter(vendor: vendor)
            for (i, text) in samples.enumerated() {
                let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
                let viaPublic = lines.map { describe(hl.scanLine($0)) }
                let viaBytes = lines.map { describe(hl.scanLine(Array($0.utf8))) }
                let oracle = allocatingLines(text, hl)
                XCTAssertEqual(viaPublic, oracle, "[\(vendor.rawValue)] String sample#\(i)")
                XCTAssertEqual(viaBytes, oracle, "[\(vendor.rawValue)] [UInt8] sample#\(i)")
            }
        }
    }

    /// The specific failure the reset exists to prevent: a busy line followed by
    /// a line with nothing on it must leave nothing behind. If a bucket kept its
    /// ranges, this line comes back with the previous line's spans; if a cursor
    /// stayed advanced, the NEXT busy line silently loses its matches.
    func testResetLeavesNothingFromThePreviousLine() {
        let hl = NetworkHighlighter(vendor: .cisco)
        let busy = Array("interface GigabitEthernet1/0/1 10.0.0.1 255.255.255.0 up".utf8)
        let quiet = Array("hello world".utf8)
        let scratch = HighlightScanner.Scratch()

        let busySpans: String = busy.withUnsafeBufferPointer { line in
            hl.scanLine(line, into: scratch)
            return describe(scratch.claimed)
        }
        XCTAssertFalse(busySpans.isEmpty, "the busy line should have matched something")

        quiet.withUnsafeBufferPointer { line in
            hl.scanLine(line, into: scratch)
            XCTAssertEqual(describe(scratch.claimed), "", "reset left the previous line behind")
            for ordinal in 0..<HighlightScanner.ruleCount {
                XCTAssertTrue(scratch.perRule[ordinal].isEmpty, "bucket \(ordinal) not reset")
                XCTAssertEqual(scratch.cursor[ordinal], 0, "cursor \(ordinal) not reset")
            }
        }

        // And the same busy line, scanned again through the used scratch, must
        // still produce what it did when the scratch was brand new.
        busy.withUnsafeBufferPointer { line in
            hl.scanLine(line, into: scratch)
            XCTAssertEqual(describe(scratch.claimed), busySpans)
        }
    }

    /// A stale CURSOR is the reuse bug that hides best: it never adds a span, it
    /// only removes one, and only from a line that comes after a longer one. So
    /// scan a document in which every rule matches late on the last line, after
    /// earlier lines have pushed all eleven cursors well past that offset.
    func testALateMatchIsNotSuppressedByAnEarlierLinesCursor() {
        let text = """
        interface GigabitEthernet1/0/1 is up, 10.0.0.1 255.255.255.0 aabb.ccdd.eeff 2001:db8::1/64 vlan 10,20
        x 1/1/1 y
        vlan 30 10.1.2.3 255.255.0.0 ffff.eeee.dddd fe80::2/64 GigabitEthernet2/0/2 down
        """
        for vendor in Vendor.allCases {
            let hl = NetworkHighlighter(vendor: vendor)
            XCTAssertEqual(
                describe(hl.spans(in: text)),
                describe(allocatingSpans(in: text, hl)),
                "[\(vendor.rawValue)] late matches"
            )
        }
    }

    /// Thai and an emoji on the same line as real tokens, with the offsets
    /// spelled out. `testWholeTextScratchPathMatchesAllocatingPathForEveryVendor`
    /// proves the two paths agree; this proves what they agree ON, so a mapping
    /// that regressed in BOTH would still be caught.
    func testThaiAndEmojiOffsetsAreUTF16() {
        let text = "ห้อง 🐑 10.0.0.1 up"
        //          0123 4  56       ^ UTF-16: "ห้อง" is 4 units, space 1,
        //          the sheep is a surrogate pair (2), space 1 -> address at 8.
        let hl = NetworkHighlighter(vendor: .cisco)
        let spans = hl.spans(in: text)
        let ns = text as NSString
        for span in spans {
            let substring = ns.substring(with: NSRange(
                location: span.range.lowerBound,
                length: span.range.upperBound - span.range.lowerBound
            ))
            switch span.rule {
            case .ipv4: XCTAssertEqual(substring, "10.0.0.1")
            case .stateGood: XCTAssertEqual(substring, "up")
            default: XCTFail("unexpected \(span.rule.rawValue) on \(substring.debugDescription)")
            }
        }
        XCTAssertEqual(spans.count, 2, describe(spans))
        XCTAssertEqual(spans.first?.range.lowerBound, 8, "UTF-16 offset of the address")
    }
}
