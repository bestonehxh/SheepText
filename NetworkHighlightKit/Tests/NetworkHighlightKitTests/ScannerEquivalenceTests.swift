import Foundation
import XCTest
@testable import NetworkHighlightKit

/// The byte scanner is a hand translation of eleven ICU regexes. These tests are
/// the only thing keeping that translation honest: the same input goes through
/// both paths and the resulting span lists must be identical, character for
/// character, for every vendor pack.
///
/// ASCII only, by contract — see `NetworkHighlightReference`. The non-ASCII
/// boundary rule this port adds is tested in `NonASCIITests`.
final class ScannerEquivalenceTests: XCTestCase {

    private func assertEquivalent(
        _ text: String, _ label: String, vendor: Vendor,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let scanner = NetworkHighlighter(vendor: vendor).spans(in: text)
        let reference = NetworkHighlightReference.referenceSpans(in: text, vendor: vendor)
        XCTAssertEqual(
            describe(scanner), describe(reference),
            "[\(vendor.rawValue)] \(label)\ninput:   \(text.debugDescription)",
            file: file, line: line
        )
        // Whatever the two paths agree on, spans must stay inside the input,
        // sorted and disjoint — a host maps them straight onto storage ranges.
        let utf16Count = text.utf16.count
        var previousEnd = 0
        for span in scanner {
            XCTAssertGreaterThanOrEqual(span.range.lowerBound, previousEnd,
                                        "[\(vendor.rawValue)] ordered/disjoint \(label)",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(span.range.upperBound, utf16Count,
                                     "[\(vendor.rawValue)] inside input \(label)",
                                     file: file, line: line)
            previousEnd = span.range.upperBound
        }
    }

    func testNeutralCorpusMatchesRegex() {
        for (i, text) in neutralCorpus.enumerated() {
            assertEquivalent(text, "corpus#\(i)", vendor: .auto)
        }
    }

    func testVendorCorpusMatchesRegexForEveryPack() {
        for vendor in Vendor.allCases {
            for (i, text) in (neutralCorpus + vendorCorpus).enumerated() {
                assertEquivalent(text, "corpus#\(i)", vendor: vendor)
            }
        }
    }

    /// Seeded, so a failure is reproducible: same seed, same 900 lines per pack.
    func testSeededFuzzMatchesRegexForEveryPack() {
        var rng = LCG(s: 4242)
        for vendor in Vendor.allCases {
            for i in 0..<900 {
                var text = ""
                for _ in 0..<(1 + rng.int(10)) { text += fuzzAtoms[rng.int(fuzzAtoms.count)] }
                assertEquivalent(text, "fuzz#\(i)", vendor: vendor)
            }
        }
    }

    /// The `.auto` pack gets its own, denser fuzz — it is what an undetected
    /// document runs and it has no interface rule to soak up ambiguous tokens.
    func testSeededFuzzOnAuto() {
        var rng = LCG()
        for i in 0..<4000 {
            var text = ""
            for _ in 0..<(1 + rng.int(12)) { text += fuzzAtoms[rng.int(fuzzAtoms.count)] }
            assertEquivalent(text, "fuzz#\(i)", vendor: .auto)
        }
    }
}
