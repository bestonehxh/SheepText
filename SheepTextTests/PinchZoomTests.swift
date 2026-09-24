//
//  PinchZoomTests.swift
//  Trackpad pinch → editor font size.
//
//  A magnify NSEvent has no public initializer, so the gesture itself is not
//  driven here; what it relies on is: the size arithmetic, a coalescer that
//  keeps up with a continuous gesture, and a font change that neither moves
//  the view nor drops the Thai fallback.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PinchZoomTests: XCTestCase {

    private var savedFontSize: Double = 0

    override func setUp() {
        super.setUp()
        savedFontSize = AppPreferences().editorFontSize
    }

    override func tearDown() {
        AppPreferences().editorFontSize = savedFontSize
        super.tearDown()
    }

    func testPinchedFontSizeIsWholePointsInsideTheSliderRange() {
        XCTAssertEqual(EditorTextView.pinchedFontSize(from: 13, magnification: 0), 13)
        XCTAssertEqual(EditorTextView.pinchedFontSize(from: 13, magnification: 1), 26)
        XCTAssertEqual(EditorTextView.pinchedFontSize(from: 13, magnification: 0.04), 14)
        XCTAssertEqual(EditorTextView.pinchedFontSize(from: 13, magnification: 5), 36)
        XCTAssertEqual(EditorTextView.pinchedFontSize(from: 13, magnification: -0.5), 9)
        XCTAssertEqual(EditorTextView.pinchedFontSize(from: 13, magnification: -3), 9)
    }

    /// The coalescer restarted its window on every change, so a gesture that
    /// steps faster than the window got the leading post and then nothing until
    /// the fingers came off the trackpad.
    func testAContinuousGestureKeepsRedrawingWhileItRuns() {
        let preferences = AppPreferences()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .editorAppearanceDidChange, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let step = AppPreferences.editorAppearanceCoalescingWindow / 3
        let steps = 12
        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) {
                preferences.editorFontSize = Double(10 + i)
            }
        }
        var postsWhileRunning = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(steps - 1)) {
            postsWhileRunning = posts
        }
        let settled = expectation(description: "gesture over and window elapsed")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + step * Double(steps) + AppPreferences.editorAppearanceCoalescingWindow * 3
        ) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertGreaterThanOrEqual(postsWhileRunning, 3,
                                    "the editor froze until the gesture stopped")
        XCTAssertLessThan(posts, steps, "every step re-highlighted every editor")
    }

    // MARK: - Font change inside a scroll view

    private struct Fixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let view: EditorTextView
        let layoutManager: NSLayoutManager
        let preferences: AppPreferences
        let document: Document
    }

    private func makeScrollingEditor(_ text: String) -> Fixture {
        let preferences = AppPreferences()
        preferences.editorFontSize = 13

        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        let view = EditorTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: container
        )
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = NSView.AutoresizingMask.width
        view.string = text
        let document = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
        view.document = document
        view.preferences = preferences
        scrollView.documentView = view

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        view.applyDocumentVisualSettings()
        layoutManager.ensureLayout(for: container)
        return Fixture(window: window, scrollView: scrollView, view: view,
                       layoutManager: layoutManager, preferences: preferences, document: document)
    }

    private func topCharacter(_ f: Fixture) -> Int {
        let clip = f.scrollView.contentView
        let point = NSPoint(x: 0, y: clip.bounds.minY - f.view.textContainerOrigin.y + 1)
        let glyph = f.layoutManager.glyphIndex(for: point, in: f.view.textContainer!)
        return f.layoutManager.characterIndexForGlyph(at: glyph)
    }

    private func scroll(_ f: Fixture, toCharacter index: Int) {
        let glyph = f.layoutManager.glyphIndexForCharacter(at: index)
        let y = f.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + f.view.textContainerOrigin.y
        f.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        f.scrollView.reflectScrolledClipView(f.scrollView.contentView)
    }

    /// The scroll offset is in points: without an anchor, doubling the font
    /// size at line 200 put roughly line 100 at the top.
    func testChangingTheFontSizeKeepsTheTopLineInPlace() {
        let lines = (0..<400).map { String(format: "line %04d", $0) }
        let f = makeScrollingEditor(lines.joined(separator: "\n") + "\n")
        let line200 = 200 * 10
        scroll(f, toCharacter: line200)
        XCTAssertEqual(topCharacter(f), line200, "fixture did not scroll")

        f.preferences.editorFontSize = 26
        f.view.applyDocumentVisualSettings()
        XCTAssertEqual(f.view.font?.pointSize, 26)
        XCTAssertEqual(topCharacter(f), line200, "zoom in moved the view")

        f.preferences.editorFontSize = 10
        f.view.applyDocumentVisualSettings()
        XCTAssertEqual(topCharacter(f), line200, "zoom out moved the view")
    }

    // `EditorViewAuditSeam` exists only in Debug; without this guard the whole
    // test target fails to compile in Release and the perf harness cannot run.
    #if DEBUG
    /// In a compare pane the anchor scroll was broadcast to the peer as a
    /// fraction of a frame laid out only down to the anchor — about 1.0 — and
    /// the other pane went to the end of its file. Compare panes keep their
    /// point offset instead, which is what they both do, so they stay aligned.
    func testACompareZoomDoesNotScrollThePaneOnItsOwn() {
        let text = (0..<400).map { String(format: "line %04d", $0) }.joined(separator: "\n") + "\n"
        let probe = EditorViewAuditSeam.Probe(text: text)
        let preferences = AppPreferences()
        preferences.editorFontSize = 13
        probe.textView.preferences = preferences
        probe.textView.applyDocumentVisualSettings()

        let peer = Document(url: nil, initialText: text, encoding: .utf8, hasBOM: false)
        probe.setComparePeer(peer)
        XCTAssertTrue(probe.textView.isComparePane)

        let clip = probe.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 1000))
        probe.scrollView.reflectScrolledClipView(clip)
        let before = clip.bounds.minY
        XCTAssertGreaterThan(before, 0, "fixture did not scroll")

        preferences.editorFontSize = 26
        probe.textView.applyDocumentVisualSettings()
        XCTAssertEqual(probe.textView.font?.pointSize, 26)
        XCTAssertEqual(clip.bounds.minY, before, "a compare pane scrolled itself on zoom")

        probe.setComparePeer(nil)
        XCTAssertFalse(probe.textView.isComparePane)
    }
    #endif

    /// `font =` replaces the font over the whole storage, and the Thai fallback
    /// was only swept onto a new storage — after any size change Thai text lost
    /// it until the file was reopened.
    func testChangingTheFontSizeKeepsTheThaiFallbackAtTheNewSize() {
        let f = makeScrollingEditor("let x = 1\nภาษาไทย\n")
        f.view.applyThaiFontFallback()
        let thai = ("let x = 1\n" as NSString).length
        let before = f.view.textStorage?.attribute(.font, at: thai, effectiveRange: nil) as? NSFont
        XCTAssertNotEqual(before?.fontName, f.view.font?.fontName, "fixture has no Thai fallback")

        f.preferences.editorFontSize = 20
        f.view.applyDocumentVisualSettings()

        let after = f.view.textStorage?.attribute(.font, at: thai, effectiveRange: nil) as? NSFont
        XCTAssertEqual(after?.fontName, before?.fontName, "Thai fallback was dropped")
        XCTAssertEqual(after?.pointSize, 20)
    }
}
