//
//  PerfHarnessAudit2TextViewTests.swift
//  Before/after workloads for the round-2 text view / gutter findings
//  (TP1, TP2, TP3, CP4).
//
//  Everything here compiles against the PRE-fix API, so the orchestrator can run
//  the same class on the old commit — with one exception, noted on the workload:
//  `textview_pinch_zoom_tick` needs `beginPinchForTesting`, which the fix
//  introduces. Its pre-fix counterpart is `textview_font_step`, which drives the
//  same code path the old pinch took (the exact anchor on every tick) and is
//  deliberately left alone by the fix — so the pair is
//
//    textview_font_step_<n>  (pre and post, unchanged)
//      → textview_pinch_zoom_tick_<n>  (post only; what a pinch now costs)
//
//  Fixture sizes are a fraction of the audit's 900 KB so a Debug (-Onone) run of
//  the class stays inside a minute; the shapes being measured are size-invariant
//  and the Release column is the one to compare against the report's numbers.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessAudit2TextViewTests: XCTestCase {

    // MARK: - Fixtures

    /// ~230 KB / 13 000 lines with a foldable brace block every four lines.
    static let braceSource: NSString = {
        var text = ""
        for i in 0..<3_250 {
            text += "func block\(i)() {\n"
            text += "    let value = \(i)\n"
            text += "    use(value)\n"
            text += "}\n"
        }
        return text as NSString
    }()

    private struct Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let view: EditorTextView
        let storage: NSTextStorage
        let layoutManager: DiffLayoutManager
        let container: NSTextContainer
    }

    private func makeEditor(_ text: String, height: CGFloat = 400) -> Fixture {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: height),
                                  textContainer: container)
        layoutManager.ownerTextView = view
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.string = text
        view.document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        layoutManager.ensureLayout(for: container)
        view.setFrameOrigin(.zero)
        scrollView.layoutSubtreeIfNeeded()
        return Fixture(window: window, scrollView: scrollView, view: view, storage: storage,
                       layoutManager: layoutManager, container: container)
    }

    // MARK: - TP3: TextLineIndex.advance's per-call buffer

    /// `lineNumbers(in:at:)` calls `advance` once per distinct offset, and each
    /// call allocated a 4096-unit (8 KB) buffer to scan a few dozen units. This
    /// is the call that made it matter: the gutter's `foldableLines` runs it for
    /// every foldable brace in the document, on every draw.
    func testPerfLineNumbersBatch() {
        let text = Self.braceSource
        let offsets = FoldingManager().foldableRanges(in: text).map(\.location)
        XCTAssertGreaterThan(offsets.count, 3_000, "fixture has too few offsets to be interesting")
        PerfHarness.measure("textlineindex_line_numbers_batch_\(offsets.count)_offsets",
                            samples: 5, iterations: 1) { () -> Int in
            let lines = TextLineIndex.lineNumbers(in: text, at: offsets)
            return lines.reduce(0, &+)
        }
    }

    // MARK: - TP2: the gutter's whole-document brace scan

    /// What a gutter draw used to pay on every keystroke, because
    /// `textChangeStamp` moves twice per keystroke and the marker cache is keyed
    /// on it. The scan itself is unchanged by the fix (the debounce is what
    /// stopped it running per character), so this number should move only
    /// through TP3.
    func testPerfGutterFoldableLines() {
        let text = Self.braceSource
        let folding = FoldingManager()
        PerfHarness.measure("gutter_fold_markers_scan_13k_lines", samples: 5, iterations: 1) { () -> Int in
            let lines = folding.foldableLines(displayText: text)
            return lines.reduce(0) { $0 ^ $1 }
        }
    }

    // MARK: - CP4: lineHighlights shifted per keystroke

    /// One keystroke against a dense diff's worth of full-width row tints. The
    /// old code rebuilt the whole array (and retained every colour) for an edit
    /// that can only move the entries after it.
    func testPerfCompareLineHighlightShift() {
        let rows = 20_000
        let text = String(repeating: "0123456789\n", count: rows)
        let f = makeEditor(text)
        let color = NSColor.red
        let template: [(range: NSRange, color: NSColor)] =
            (0..<rows).map { (range: NSRange(location: $0 * 11, length: 11), color: color) }

        // Type one character near the TOP, so the edit is as expensive as it
        // ever gets: everything below it has to move.
        let caret = NSRange(location: 11, length: 0)
        PerfHarness.measure("compare_linehighlight_shift_\(rows)", samples: 5, iterations: 1) { () -> Int in
            f.layoutManager.lineHighlights = template
            f.storage.replaceCharacters(in: caret, with: "x")
            let checksum = f.layoutManager.lineHighlights.reduce(0) { $0 &+ $1.range.location }
            f.storage.replaceCharacters(in: NSRange(location: 11, length: 1), with: "")
            return checksum
        }
    }

    // MARK: - TP1: a font-size step with the viewport near the end

    /// The pre-fix cost of one pinch tick, and still the cost of one Settings
    /// slider step: the anchor is resolved by character, which forces layout of
    /// everything above it after the font change invalidated the document.
    func testPerfFontStepWithTheViewportNearTheEnd() {
        let lines = (0..<12_000).map { String(format: "line %05d", $0) }
        let f = makeEditor(lines.joined(separator: "\n") + "\n")
        let preferences = AppPreferences()
        let savedSize = preferences.editorFontSize
        defer { preferences.editorFontSize = savedSize }
        preferences.editorFontSize = 13
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        f.layoutManager.ensureLayout(for: f.container)
        scrollNearTheEnd(f)

        var size = 13.0
        PerfHarness.measure("textview_font_step_12k_lines", samples: 5, iterations: 1) { () -> Int in
            size = size == 13.0 ? 14.0 : 13.0
            preferences.editorFontSize = size
            f.view.applyDocumentVisualSettings()
            return Int(f.scrollView.contentView.bounds.minY)
        }
    }

    /// The same step inside a pinch. Post-fix only: `beginPinchForTesting` is
    /// introduced by the fix (a magnify NSEvent has no public initializer, so
    /// there is no other way to drive the gesture state). Compare against
    /// `textview_font_step_12k_lines` on either commit.
    func testPerfPinchZoomTick() {
        let lines = (0..<12_000).map { String(format: "line %05d", $0) }
        let f = makeEditor(lines.joined(separator: "\n") + "\n")
        let preferences = AppPreferences()
        let savedSize = preferences.editorFontSize
        defer { preferences.editorFontSize = savedSize }
        preferences.editorFontSize = 13
        f.view.preferences = preferences
        f.view.applyDocumentVisualSettings()
        f.layoutManager.ensureLayout(for: f.container)
        scrollNearTheEnd(f)

        f.view.beginPinchForTesting()
        defer { f.view.endPinchForTesting() }
        var size = 13.0
        PerfHarness.measure("textview_pinch_zoom_tick_12k_lines", samples: 5, iterations: 1) { () -> Int in
            size = size == 13.0 ? 14.0 : 13.0
            preferences.editorFontSize = size
            f.view.applyDocumentVisualSettings()
            return Int(f.scrollView.contentView.bounds.minY)
        }
    }

    /// 90 % of the way down, which is where the anchor's forced layout hurts.
    private func scrollNearTheEnd(_ f: Fixture) {
        let index = Int(Double(f.storage.length) * 0.9)
        let glyph = f.layoutManager.glyphIndexForCharacter(at: index)
        let y = f.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + f.view.textContainerOrigin.y
        f.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        f.scrollView.reflectScrolledClipView(f.scrollView.contentView)
    }
}
