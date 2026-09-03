//
//  HighlightRunTests.swift
//  The syntax engine's output format: the painter that builds runs, the algebra
//  that moves them across an edit, and the palette that colours them.
//
//  These are the pieces the viewport apply rests on. If `shifting` is wrong the
//  colours slide off the text between a keystroke and the next parse; if
//  `replacing` is wrong an incremental pass silently loses tokens; if the
//  palette ever grows a font the whole design is void, because a temporary
//  attribute cannot change layout.
//

import AppKit
import XCTest
@testable import SheepText

final class HighlightRunPainterTests: XCTestCase {

    private let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
    private let string = HighlightStyleTable.styleID(forCapture: "string")

    func testAdjacentCharactersOfOneStyleBecomeOneRun() {
        var painter = HighlightRunPainter(bounds: NSRange(location: 0, length: 10))
        painter.paint(keyword, in: NSRange(location: 2, length: 3))
        painter.paint(keyword, in: NSRange(location: 5, length: 2))
        XCTAssertEqual(painter.runs(), [
            HighlightRun(location: 2, length: 5, style: keyword)
        ])
    }

    /// Captures nest, and the innermost paint wins — the semantics
    /// `NSMutableAttributedString.addAttributes` used to give for free.
    func testLaterPaintsWin() {
        var painter = HighlightRunPainter(bounds: NSRange(location: 0, length: 10))
        painter.paint(keyword, in: NSRange(location: 0, length: 10))
        painter.paint(string, in: NSRange(location: 4, length: 2))
        XCTAssertEqual(painter.runs(), [
            HighlightRun(location: 0, length: 4, style: keyword),
            HighlightRun(location: 4, length: 2, style: string),
            HighlightRun(location: 6, length: 4, style: keyword)
        ])
    }

    /// A capture that resolves to no style must leave what is underneath it
    /// alone. This was `guard !attrs.isEmpty` before, and it is load-bearing:
    /// `@none`-style captures are common in grammars.
    func testAnUnstyledCaptureDoesNotEraseTheStyleUnderIt() {
        var painter = HighlightRunPainter(bounds: NSRange(location: 0, length: 6))
        painter.paint(keyword, in: NSRange(location: 0, length: 6))
        painter.paint(HighlightStyleTable.none, in: NSRange(location: 2, length: 2))
        XCTAssertEqual(painter.runs(), [HighlightRun(location: 0, length: 6, style: keyword)])
        XCTAssertEqual(HighlightStyleTable.styleID(forCapture: "no.such.capture"),
                       HighlightStyleTable.none,
                       "an unknown capture must resolve to no style")
    }

    /// The painter is bounded by a *set* of ranges, not one range: an
    /// incremental pass repaints paragraphs that can sit far apart, and a
    /// scratch buffer spanning the gap would be the size of the document.
    func testPaintsOutsideTheBoundsAreDropped() {
        var painter = HighlightRunPainter(bounds: [
            NSRange(location: 0, length: 4),
            NSRange(location: 100, length: 4)
        ])
        painter.paint(keyword, in: NSRange(location: 0, length: 200))
        XCTAssertEqual(painter.runs(), [
            HighlightRun(location: 0, length: 4, style: keyword),
            HighlightRun(location: 100, length: 4, style: keyword)
        ])
    }

    func testCaptureNamesResolveHierarchically() {
        XCTAssertEqual(HighlightStyleTable.styleID(forCapture: "keyword.function.builtin"),
                       HighlightStyleTable.styleID(forCapture: "keyword"))
        XCTAssertEqual(HighlightStyleTable.styleID(forCapture: "@keyword"),
                       HighlightStyleTable.styleID(forCapture: "keyword"))
        XCTAssertNotEqual(HighlightStyleTable.styleID(forCapture: "keyword.type"),
                          HighlightStyleTable.styleID(forCapture: "keyword"))
    }
}

final class HighlightRunListTests: XCTestCase {

    private let a = HighlightStyleTable.styleID(forCapture: "keyword")
    private let b = HighlightStyleTable.styleID(forCapture: "string")

    // MARK: shifting

    func testInsertionBeforeARunMovesIt() {
        let runs = [HighlightRun(location: 10, length: 5, style: a)]
        XCTAssertEqual(
            HighlightRunList.shifting(runs, replacing: NSRange(location: 0, length: 0), withLength: 3),
            [HighlightRun(location: 13, length: 5, style: a)]
        )
    }

    func testInsertionInsideARunStretchesIt() {
        let runs = [HighlightRun(location: 10, length: 5, style: a)]
        XCTAssertEqual(
            HighlightRunList.shifting(runs, replacing: NSRange(location: 12, length: 0), withLength: 2),
            [HighlightRun(location: 10, length: 7, style: a)]
        )
    }

    func testInsertionAfterARunLeavesItAlone() {
        let runs = [HighlightRun(location: 10, length: 5, style: a)]
        XCTAssertEqual(
            HighlightRunList.shifting(runs, replacing: NSRange(location: 40, length: 0), withLength: 4),
            runs
        )
    }

    /// The case a point-shift gets wrong, and the one that made
    /// `DiffLayoutManager.processEditing` corrupt its highlights: a selection
    /// replace spanning several runs.
    func testAReplacementSpanningRunsTrimsTheEndsAndDropsTheMiddle() {
        let runs = [
            HighlightRun(location: 0, length: 10, style: a),
            HighlightRun(location: 10, length: 10, style: b),
            HighlightRun(location: 20, length: 10, style: a)
        ]
        let shifted = HighlightRunList.shifting(
            runs, replacing: NSRange(location: 5, length: 20), withLength: 1
        )
        XCTAssertEqual(shifted, [
            HighlightRun(location: 0, length: 5, style: a),
            HighlightRun(location: 6, length: 5, style: a)
        ])
    }

    func testARunEntirelyInsideTheReplacementIsDropped() {
        let runs = [HighlightRun(location: 10, length: 4, style: a)]
        XCTAssertEqual(
            HighlightRunList.shifting(runs, replacing: NSRange(location: 8, length: 10), withLength: 0),
            []
        )
    }

    // MARK: replacing

    func testFreshRunsReplaceWhatWasInTheRepaintedRange() {
        let old = [
            HighlightRun(location: 0, length: 5, style: a),
            HighlightRun(location: 10, length: 5, style: a)
        ]
        let fresh = [HighlightRun(location: 11, length: 2, style: b)]
        XCTAssertEqual(
            HighlightRunList.replacing(old, in: [NSRange(location: 10, length: 5)], with: fresh),
            [
                HighlightRun(location: 0, length: 5, style: a),
                HighlightRun(location: 11, length: 2, style: b)
            ]
        )
    }

    /// A block comment crossing the repainted paragraph must be trimmed at the
    /// boundary, not dropped whole and not left overlapping the new runs.
    func testARunStraddlingTheRepaintedRangeIsTrimmedOnBothSides() {
        let old = [HighlightRun(location: 0, length: 100, style: a)]
        let fresh = [HighlightRun(location: 40, length: 10, style: b)]
        XCTAssertEqual(
            HighlightRunList.replacing(old, in: [NSRange(location: 30, length: 30)], with: fresh),
            [
                HighlightRun(location: 0, length: 30, style: a),
                HighlightRun(location: 40, length: 10, style: b),
                HighlightRun(location: 60, length: 40, style: a)
            ]
        )
    }

    func testTheResultStaysSortedAcrossSeveralRepaintedRanges() {
        let old = (0..<10).map { HighlightRun(location: $0 * 10, length: 10, style: a) }
        let fresh = [
            HighlightRun(location: 22, length: 4, style: b),
            HighlightRun(location: 71, length: 3, style: b)
        ]
        let result = HighlightRunList.replacing(
            old,
            in: [NSRange(location: 20, length: 10), NSRange(location: 70, length: 10)],
            with: fresh
        )
        XCTAssertEqual(result, result.sorted { $0.location < $1.location })
        for (index, run) in result.enumerated().dropFirst() {
            XCTAssertGreaterThanOrEqual(run.location, result[index - 1].end,
                                        "runs must stay non-overlapping")
        }
        XCTAssertTrue(result.contains(HighlightRun(location: 22, length: 4, style: b)))
        XCTAssertTrue(result.contains(HighlightRun(location: 71, length: 3, style: b)))
    }

    // MARK: lookup

    func testStyleLookupFindsTheRunCoveringAnIndex() {
        let runs = [
            HighlightRun(location: 0, length: 5, style: a),
            HighlightRun(location: 10, length: 5, style: b)
        ]
        XCTAssertEqual(HighlightRunList.style(at: 3, in: runs), a)
        XCTAssertEqual(HighlightRunList.style(at: 7, in: runs), HighlightStyleTable.none)
        XCTAssertEqual(HighlightRunList.style(at: 14, in: runs), b)
        XCTAssertEqual(HighlightRunList.style(at: 15, in: runs), HighlightStyleTable.none)
    }
}

final class HighlightPaletteTests: XCTestCase {

    /// The design's load-bearing constraint. `NSLayoutManager` never re-lays-out
    /// when a temporary attribute changes, so a style that changed glyph metrics
    /// would paint text at the wrong advances. Bold and italic are therefore
    /// `.strokeWidth` / `.obliqueness` — which skew and outline the same glyphs
    /// — and never a bold or italic FONT.
    @MainActor
    func testNoStyleCarriesALayoutAffectingAttribute() {
        for isDark in [true, false] {
            let palette = HighlightPalette(isDark: isDark)
            for index in HighlightStyleTable.styles.indices {
                let attributes = palette.attributes(for: HighlightStyleID(index))
                for key in HighlightStyleTable.layoutAffectingKeys {
                    XCTAssertNil(attributes[key],
                                 "style \(HighlightStyleTable.styles[index].scope) carries \(key.rawValue)")
                }
                for key in attributes.keys {
                    XCTAssertTrue(
                        HighlightStyleTable.ownedAttributeKeys.contains(key),
                        "style \(HighlightStyleTable.styles[index].scope) emits \(key.rawValue), " +
                        "which the apply layer does not know to clean up"
                    )
                }
            }
        }
    }

    /// A run is appearance-independent: the same list paints light or dark.
    /// That is what makes a theme flip a repaint instead of a re-parse.
    @MainActor
    func testTheSameStyleResolvesToDifferentColoursPerAppearance() {
        let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
        let dark = HighlightPalette(isDark: true).attributes(for: keyword)[.foregroundColor] as? NSColor
        let light = HighlightPalette(isDark: false).attributes(for: keyword)[.foregroundColor] as? NSColor
        XCTAssertNotNil(dark)
        XCTAssertNotNil(light)
        XCTAssertNotEqual(dark, light)
    }

    /// Emphasis is the only place any style carries more than a colour.
    func testEmphasisIsRenderedWithoutAFont() {
        let italic = HighlightStyleTable.attributes(
            HighlightStyleTable.styleID(forCapture: "emphasis"), isDark: true
        )
        let bold = HighlightStyleTable.attributes(
            HighlightStyleTable.styleID(forCapture: "emphasis.strong"), isDark: true
        )
        XCTAssertNotNil(italic[.obliqueness])
        XCTAssertNotNil(bold[.strokeWidth])
        XCTAssertNil(italic[.font])
        XCTAssertNil(bold[.font])
    }

    /// The `NSAttributedString` shim the tests and benchmarks use has to say the
    /// same thing the runs do.
    func testMaterialisingRunsMatchesTheRunsThemselves() {
        let text = "let value = 1\n"
        let keyword = HighlightStyleTable.styleID(forCapture: "keyword")
        let runs = [HighlightRun(location: 0, length: 3, style: keyword)]
        let string = HighlightRunList.attributedString(text: text, runs: runs, isDark: true)
        XCTAssertEqual(
            string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            HighlightStyleTable.color(keyword, isDark: true)
        )
        XCTAssertNil(string.attribute(.foregroundColor, at: 4, effectiveRange: nil))
    }
}

/// Proof that the three keys the palette emits actually render through
/// `NSLayoutManager`'s temporary attributes.
///
/// "Temporary attributes are for things that do not affect layout" is a rule
/// about what you MAY put there, not a list of what TextKit honours, and the
/// documentation gives no list. Since the whole design rests on the answer,
/// this renders the same glyphs twice — once plain, once with the attribute —
/// and compares the pixels. `.obliqueness` and `.strokeWidth` are how the
/// palette expresses markdown italic and bold; if they had turned out to be
/// ignored, the honest fix would have been to drop emphasis rather than to put
/// a bold FONT (which changes advances, and therefore layout) on this path.
@MainActor
final class TemporaryAttributeRenderingTests: XCTestCase {

    private func render(_ apply: (NSLayoutManager, NSRange) -> Void) throws -> Data {
        let storage = NSTextStorage(string: "MMMM iiii")
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 300, height: 60))
        layoutManager.addTextContainer(container)
        storage.setAttributes(
            [
                .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                .foregroundColor: NSColor.black
            ],
            range: NSRange(location: 0, length: storage.length)
        )
        apply(layoutManager, NSRange(location: 0, length: storage.length))
        layoutManager.ensureLayout(for: container)

        let image = NSImage(size: NSSize(width: 300, height: 60))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 60).fill()
        layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: container), at: .zero)
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testEveryKeyThePaletteEmitsChangesWhatIsDrawn() throws {
        let plain = try render { _, _ in }
        for key in HighlightStyleTable.ownedAttributeKeys {
            let value: Any
            switch key {
            case .foregroundColor: value = NSColor.red
            case .obliqueness: value = 0.3
            case .strokeWidth: value = -6.0
            default: return XCTFail("no probe value for \(key.rawValue)")
            }
            let painted = try render { layoutManager, range in
                layoutManager.addTemporaryAttributes([key: value], forCharacterRange: range)
            }
            XCTAssertNotEqual(
                painted, plain,
                "\(key.rawValue) is ignored as a temporary attribute — the palette cannot use it"
            )
        }
    }
}
