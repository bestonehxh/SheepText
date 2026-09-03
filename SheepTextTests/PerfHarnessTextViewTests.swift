//
//  PerfHarnessTextViewTests.swift
//  Before/after workloads for the EditorTextView audit fixes.
//
//  Written against the API as it exists BEFORE the fixes, because the
//  orchestrator runs this class on the pre-fix commit too. Nothing here may
//  reference a symbol introduced by a fix, so every workload drives a method
//  that was already `internal` or `override`:
//
//    textview_postSelectionInfo_1000_moves   → setSelectedRange (T7)
//    textview_thai_fallback_500k_ascii       → applyThaiFontFallback (S10)
//    textview_thai_fallback_500k_thai        → applyThaiFontFallback (S10)
//    textview_draw_invisibles_on/_off        → draw(_:) (T9); the invisible-
//                                              character cost is on − off,
//                                              since super.draw dominates both
//                                              and is identical either way.
//    textview_click_ensureLayout_full_320KB  → the layout pass the T10 fix
//                                              stops asking for. Same number on
//                                              both commits: it measures the
//                                              work REMOVED, not the new path
//                                              (mouseDown cannot be driven from
//                                              a test — super.mouseDown runs an
//                                              event-tracking loop).
//
//  Fixture sizes keep a Debug (-Onone) run of the whole class under a minute.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessTextViewTests: XCTestCase {

    // MARK: - Fixtures

    /// ~256 KB of LF-terminated ASCII, 16 UTF-16 units per line. The shape
    /// being measured is O(offset) per lookup; 1 MB makes the same point and
    /// takes 144 s in a Debug run, which is not a measurement anyone repeats.
    static let asciiSource: String = String(repeating: "0123456789abcde\n", count: 256 * 1024 / 16)

    /// ~500k UTF-16 units of ASCII.
    static let ascii500k: String = String(repeating: "0123456789abcde\n", count: 500_000 / 16)

    /// ~500k UTF-16 units, one quarter of it Thai.
    static let thai500k: String = {
        let unit = "abcdefgh \u{0E01}\u{0E48}\u{0E02}\u{0E23}\u{0E39}\u{0E1C} ij\n"   // 24 units
        return String(repeating: unit, count: 500_000 / 24)
    }()

    /// The same manual TextKit 1 stack `EditorView.makeNSView` builds. A bare
    /// `NSTextView(frame:)` is TextKit 2 on macOS 13+ and has no layoutManager.
    private func makeEditor(
        _ text: String,
        width: CGFloat = 700,
        height: CGFloat = 500
    ) -> (window: NSWindow, view: EditorTextView, document: Document, layoutManager: NSLayoutManager) {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = EditorTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            textContainer: container
        )
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text

        let document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
        view.document = document

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        return (window, view, document, layoutManager)
    }

    // MARK: - T7 — line/column reporting on every cursor move

    /// The caret near the end of a 1 MB document, moving one unit at a time —
    /// which is what arrowing along a line does. Each `setSelectedRange` posts
    /// the status-bar info, and computing it was an O(offset) newline count
    /// from byte 0.
    func testPerfPostSelectionInfoSequentialMoves() {
        let (_, view, _, _) = makeEditor(Self.asciiSource, width: 700, height: 200)
        guard let storage = view.textStorage else { return XCTFail("no storage") }
        let end = storage.length

        PerfHarness.measure("textview_postSelectionInfo_1000_moves", samples: 5, iterations: 1) {
            var checksum = 0
            for step in 0..<1000 {
                let location = end - 1000 + step
                view.setSelectedRange(NSRange(location: location, length: 0))
                checksum &+= view.selectedRange().location
            }
            return checksum
        }
    }

    // MARK: - S10 — Thai font fallback over a whole document

    func testPerfThaiFallbackAsciiDocument() {
        let (_, view, _, _) = makeEditor(Self.ascii500k)
        guard let storage = view.textStorage else { return XCTFail("no storage") }

        PerfHarness.measure("textview_thai_fallback_500k_ascii", samples: 5, iterations: 1) {
            view.applyThaiFontFallback(in: NSRange(location: 0, length: storage.length))
            return storage.length
        }
    }

    func testPerfThaiFallbackThaiDocument() {
        let (_, view, _, _) = makeEditor(Self.thai500k)
        guard let storage = view.textStorage else { return XCTFail("no storage") }

        PerfHarness.measure("textview_thai_fallback_500k_thai", samples: 5, iterations: 1) {
            view.applyThaiFontFallback(in: NSRange(location: 0, length: storage.length))
            return storage.length
        }
    }

    // MARK: - T9 — invisible characters in a frame

    /// One `draw(_:)` over a screenful of indented text. `super.draw` is the
    /// bulk of both numbers and is untouched by the fix, so read the pair:
    /// the invisible-character work is `_on` minus `_off`.
    private func measureDraw(_ name: String, showsInvisibles: Bool) {
        let indented = String(repeating: "    let value = compute(a, b)\t// note\n", count: 4000)
        let (_, view, document, layoutManager) = makeEditor(indented, width: 700, height: 500)
        document.showsInvisibleCharacters = showsInvisibles
        guard let container = view.textContainer else { return XCTFail("no container") }
        layoutManager.ensureLayout(for: container)

        let rect = NSRect(x: 0, y: 0, width: 700, height: 500)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 700, pixelsHigh: 500,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return XCTFail("no bitmap context")
        }

        PerfHarness.measure(name, samples: 5, iterations: 1) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.draw(rect)
            NSGraphicsContext.restoreGraphicsState()
            return Int(rect.width)
        }
    }

    func testPerfDrawWithInvisibleCharacters() {
        measureDraw("textview_draw_invisibles_on", showsInvisibles: true)
    }

    func testPerfDrawWithoutInvisibleCharacters() {
        measureDraw("textview_draw_invisibles_off", showsInvisibles: false)
    }

    // MARK: - T10 — the layout pass a click used to force

    /// `shouldClampClickToDocumentEnd` opened with `ensureLayout(for:)` — glyph
    /// generation and layout for the WHOLE container, to answer one mouse
    /// click. Layout is invalidated by every edit, so the first click after a
    /// keystroke paid this again. The workload lays out only a screenful (what
    /// drawing would have done) and then measures the full pass, i.e. exactly
    /// the work the fix stops asking for. It measures the same thing on both
    /// commits by design — the post-fix path performs none of it.
    func testPerfClickForcedFullLayout() {
        let source = String(repeating: "0123456789abcde\n", count: 20_000)   // ~320 KB
        let (_, view, _, layoutManager) = makeEditor(source)
        guard let container = view.textContainer, let storage = view.textStorage else {
            return XCTFail("no TextKit 1 stack")
        }

        PerfHarness.measure("textview_click_ensureLayout_full_320KB", samples: 5, iterations: 1) {
            layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: storage.length),
                actualCharacterRange: nil
            )
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: 4_000))
            layoutManager.ensureLayout(for: container)
            return layoutManager.numberOfGlyphs
        }
    }
}
