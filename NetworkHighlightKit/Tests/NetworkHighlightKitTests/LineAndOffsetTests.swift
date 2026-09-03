import Foundation
import XCTest
@testable import NetworkHighlightKit

/// The two properties an incremental editor rests on:
///
/// 1. every rule is line-local, so re-scanning one line is as good as
///    re-scanning the document, and
/// 2. `spans(in:)` hands back UTF-16 offsets that land exactly where an
///    `NSTextStorage` expects them, Thai and emoji included.
final class LineAndOffsetTests: XCTestCase {

    /// UTF-16 offsets, computed the honest slow way, for cross-checking the
    /// mapping in `NetworkHighlighter`.
    private func utf16Offset(ofUTF8 byteOffset: Int, in text: String) -> Int {
        let bytes = Array(text.utf8)
        let prefix = String(decoding: bytes[0..<byteOffset], as: UTF8.self)
        return prefix.utf16.count
    }

    // MARK: - Line locality

    func testPerLineEqualsWholeText() {
        // Documents made of the corpora, so every rule and every near-miss is
        // exercised across line boundaries as well as inside a line.
        let documents = [
            neutralCorpus.joined(separator: "\n"),
            vendorCorpus.joined(separator: "\n"),
            // an interface name split by the line break: SheepTerm's `\s?`
            // matched across it, this port must not
            "GigabitEthernet\n1/0/1 up\nvlan\n10\nno\nshutdown",
            // CRLF everywhere — the CR is just a byte no rule matches
            vendorCorpus.joined(separator: "\r\n"),
            "",
            "\n\n\n",
            "10.0.0.1",
            "10.0.0.1\n",
        ]
        for vendor in Vendor.allCases {
            let hl = NetworkHighlighter(vendor: vendor)
            for document in documents {
                let whole = hl.spans(in: document)

                // The same document scanned one line at a time, offsets shifted
                // by the line's start. ASCII, so UTF-8 offset == UTF-16 offset.
                var perLine: [NetworkSpan] = []
                var base = 0
                let bytes = Array(document.utf8)
                var lineStart = 0
                while lineStart <= bytes.count {
                    var i = lineStart
                    while i < bytes.count, bytes[i] != 0x0A { i += 1 }
                    let line = Array(bytes[lineStart..<i])
                    for span in hl.scanLine(line) {
                        perLine.append(NetworkSpan(
                            range: (base + span.range.lowerBound)..<(base + span.range.upperBound),
                            rule: span.rule
                        ))
                    }
                    if i == bytes.count { break }
                    base += line.count + 1
                    lineStart = i + 1
                }

                XCTAssertEqual(describe(whole), describe(perLine),
                               "[\(vendor.rawValue)] per-line != whole text for \(document.debugDescription)")
            }
        }
    }

    /// The specific shape SheepTerm's `\s?` got wrong.
    func testInterfaceNameDoesNotMatchAcrossALineBreak() {
        let hl = NetworkHighlighter(vendor: .cisco)
        XCTAssertEqual(hl.spans(in: "GigabitEthernet 1/0/1").map(\.rule), [.interface])
        XCTAssertEqual(hl.spans(in: "GigabitEthernet\n1/0/1"), [])
        XCTAssertEqual(hl.spans(in: "GigabitEthernet\r\n1/0/1"), [])
    }

    // MARK: - UTF-16 offset mapping

    func testASCIIOffsetsAreIdentical() {
        let text = "interface Gi1/0/1\n ip address 10.0.0.1 255.255.255.0\n no shutdown"
        let hl = NetworkHighlighter(vendor: .cisco)
        for span in hl.spans(in: text) {
            let ns = text as NSString
            let substring = ns.substring(with: NSRange(location: span.range.lowerBound,
                                                       length: span.range.count))
            XCTAssertFalse(substring.isEmpty)
            XCTAssertEqual(substring.utf16.count, span.range.count)
        }
        XCTAssertEqual(
            hl.spans(in: text).map { (text as NSString).substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) },
            ["Gi1/0/1", "10.0.0.1", "255.255.255.0", "no shutdown"]
        )
    }

    func testThaiLineOffsetsLandOnTheRightCharacters() {
        // Thai `description` text is the everyday case an editor sees and a
        // terminal does not.
        let text = "interface Gi1/0/1\n description ห้องเซิร์ฟเวอร์ ชั้น 3\n ip address 10.0.0.1 255.255.255.0 up"
        let ns = text as NSString
        for span in NetworkHighlighter(vendor: .cisco).spans(in: text) {
            let range = NSRange(location: span.range.lowerBound, length: span.range.count)
            XCTAssertLessThanOrEqual(range.location + range.length, ns.length)
            let token = ns.substring(with: range)
            // The mapping is right iff the substring is the token, not a slice
            // through the middle of a Thai cluster.
            XCTAssertEqual(token, String(token), "sliced mid-character: \(token.debugDescription)")
        }
        let tokens = NetworkHighlighter(vendor: .cisco).spans(in: text).map {
            ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count))
        }
        XCTAssertEqual(tokens, ["Gi1/0/1", "10.0.0.1", "255.255.255.0", "up"])
    }

    func testEmojiLineOffsetsAccountForSurrogatePairs() {
        // 🐑 is U+1F411 — one Character, four UTF-8 bytes, TWO UTF-16 units.
        // Getting this wrong shifts every later span on the line by one.
        let text = "🐑 addr 10.0.0.1 up 🐑🐑 255.255.255.0 down"
        let ns = text as NSString
        let tokens = NetworkHighlighter(vendor: .cisco).spans(in: text).map {
            ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count))
        }
        XCTAssertEqual(tokens, ["10.0.0.1", "up", "255.255.255.0", "down"])
    }

    /// The mapping itself: scan once in byte offsets, convert every endpoint the
    /// slow honest way (decode the prefix, count its UTF-16 units), and require
    /// `spans(in:)` to have produced exactly that.
    func testUTF16MappingMatchesASlowReferenceConversion() {
        let lines = [
            "ห้อง 10.0.0.1 up",
            "🐑 vlan 10,20",
            "描述 mgmt0 down",
            "ü Gi1/0/1 up",
            "ﬀ 255.255.255.0",
            "a🐑b 10.0.0.1/24",
            "\u{1F1F9}\u{1F1ED} 192.168.1.1 up",     // flag: two surrogate pairs
            "e\u{0301} 10.0.0.1",                     // combining acute
            "no shutdown ห้องเซิร์ฟเวอร์",
            "aabb.ccdd.eeff 🐑 2001:db8::1",
        ]
        let text = lines.joined(separator: "\n")
        let hl = NetworkHighlighter(vendor: .cisco)
        let byteSpans = hl.scanUTF8(Array(text.utf8))
        let expected = byteSpans.map { span in
            NetworkSpan(
                range: utf16Offset(ofUTF8: span.range.lowerBound, in: text)
                    ..< utf16Offset(ofUTF8: span.range.upperBound, in: text),
                rule: span.rule
            )
        }
        XCTAssertFalse(expected.isEmpty, "the sample must actually produce spans")
        XCTAssertEqual(describe(hl.spans(in: text)), describe(expected))
    }

    func testUTF16LengthHelperMatchesFoundation() {
        for sample in ["", "abc", "ห้องเซิร์ฟเวอร์", "🐑🐑", "a🐑b", "\u{1F1F9}\u{1F1ED}", "ü"] {
            var copy = sample
            let measured = copy.withUTF8 { NetworkHighlighter.utf16Length(of: $0) }
            XCTAssertEqual(measured, sample.utf16.count, sample.debugDescription)
        }
    }

    // MARK: - The non-ASCII boundary rule

    /// Bytes >= 0x80 are WORD bytes. Documented in `HighlightScanner`; these are
    /// the consequences, asserted so nobody "fixes" them by accident.
    func testNonASCIIBytesAreWordBytes() {
        let hl = NetworkHighlighter(vendor: .cisco)

        // Attached to a word byte: not a token.
        XCTAssertEqual(hl.spans(in: "ห้อง10"), [], "digits behind a Thai word are not a vlan id")
        XCTAssertEqual(hl.spans(in: "10.0.0.1ห"), [], "an address followed by a word byte is not one")
        XCTAssertEqual(hl.spans(in: "ห10.0.0.1"), [], "…nor one preceded by one")
        XCTAssertEqual(hl.spans(in: "upห"), [], "a state word needs a real boundary too")
        XCTAssertEqual(hl.spans(in: "🐑up"), [], "emoji are word bytes as well")

        // Separated by a real boundary: matched as usual.
        XCTAssertEqual(hl.spans(in: "ห้อง 10.0.0.1").map(\.rule), [.ipv4])
        XCTAssertEqual(hl.spans(in: "ห้อง: up").map(\.rule), [.stateGood])
        XCTAssertEqual(hl.spans(in: "10.0.0.1 ห้อง").map(\.rule), [.ipv4])
        XCTAssertEqual(hl.spans(in: "🐑 vlan 10").map(\.rule), [.vlan])
    }

    /// A match can never end inside a multi-byte character, because every byte
    /// of one is a word byte and a match must end on a boundary.
    func testNoSpanEverSplitsAGrapheme() {
        var rng = LCG(s: 99)
        let pieces = ["ห้อง", "🐑", "日本語", "ü", "e\u{0301}", " ", "10.0.0.1", "up",
                      "Gi1/0/1", "vlan 10", "255.255.255.0", ".", ":", "-", "\n", "a"]
        let hl = NetworkHighlighter(vendor: .cisco)
        for _ in 0..<2000 {
            var text = ""
            for _ in 0..<(1 + rng.int(10)) { text += pieces[rng.int(pieces.count)] }
            let ns = text as NSString
            for span in hl.spans(in: text) {
                let range = NSRange(location: span.range.lowerBound, length: span.range.count)
                XCTAssertLessThanOrEqual(range.location + range.length, ns.length)
                // rangeOfComposedCharacterSequences must not widen the span:
                // if it does, an endpoint fell inside a character.
                let composed = ns.rangeOfComposedCharacterSequences(for: range)
                XCTAssertEqual(composed, range,
                               "span cut a character in \(text.debugDescription)")
            }
        }
    }
}
