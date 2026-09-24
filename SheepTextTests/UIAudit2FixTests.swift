//
//  UIAudit2FixTests.swift
//  Regression tests for the app / UI findings of the second (Sept 17 2026)
//  audit. One test (or group) per finding id; the id is named in each test's
//  comment so a failure points straight back at what it is protecting.
//

import AppKit
import SwiftUI
import XCTest
@testable import SheepText

// MARK: - US3 — the update check trusts whatever the response carried

final class UpdateDownloadURLTests: XCTestCase {

    /// The release JSON's `html_url` went straight to `NSWorkspace.open`, which
    /// honours `file://` and every registered custom scheme — and the app is
    /// unsandboxed now, so whatever it launched was unconstrained. "Download"
    /// has to mean one thing.
    func testAReleasePageOnGitHubIsAccepted() {
        XCTAssertEqual(
            UpdateChecker.downloadURL(
                htmlURL: "https://github.com/bestonehxh/SheepText/releases/tag/v3.7"
            ).absoluteString,
            "https://github.com/bestonehxh/SheepText/releases/tag/v3.7"
        )
    }

    func testAFileURLFallsBackToTheReleasesPage() {
        XCTAssertEqual(
            UpdateChecker.downloadURL(htmlURL: "file:///Applications/Calculator.app"),
            UpdateChecker.releasesPageURL
        )
    }

    func testPlainHTTPFallsBackToTheReleasesPage() {
        XCTAssertEqual(
            UpdateChecker.downloadURL(htmlURL: "http://github.com/bestonehxh/SheepText/releases"),
            UpdateChecker.releasesPageURL
        )
    }

    /// A host that merely starts with "github.com" is a different host, and one
    /// that merely contains it is somebody else's domain entirely.
    func testALookalikeHostFallsBackToTheReleasesPage() {
        for host in ["githubb.com", "github.com.evil.example", "evil.example"] {
            XCTAssertEqual(
                UpdateChecker.downloadURL(htmlURL: "https://\(host)/bestonehxh/SheepText/releases"),
                UpdateChecker.releasesPageURL,
                "\(host) was accepted"
            )
        }
    }

    /// Right host, wrong repository: still not this app's download.
    func testAnotherRepositoryFallsBackToTheReleasesPage() {
        XCTAssertEqual(
            UpdateChecker.downloadURL(htmlURL: "https://github.com/someone/else/releases/tag/v1"),
            UpdateChecker.releasesPageURL
        )
    }

    /// `/bestonehxh/SheepTextEvil` shares a string prefix with the real repo
    /// path but is a different repository — the check is per path component.
    func testARepositoryWhoseNameSharesAPrefixIsRejected() {
        XCTAssertEqual(
            UpdateChecker.downloadURL(htmlURL: "https://github.com/bestonehxh/SheepTextEvil/releases"),
            UpdateChecker.releasesPageURL
        )
    }

    func testGarbageFallsBackToTheReleasesPage() {
        XCTAssertEqual(UpdateChecker.downloadURL(htmlURL: ""), UpdateChecker.releasesPageURL)
        XCTAssertEqual(UpdateChecker.downloadURL(htmlURL: "not a url at all"),
                       UpdateChecker.releasesPageURL)
    }

    /// The `URLResponse` was discarded, so an HTTP 403 — which is what the
    /// unauthenticated GitHub API answers after 60 requests an hour — was fed
    /// to the JSON decoder. It threw, and the launch path swallows errors
    /// silently while the menu item blamed the user's internet connection.
    func testRateLimitIsItsOwnError() {
        XCTAssertEqual(UpdateChecker.responseError(forStatusCode: 403)?.errorDescription,
                       UpdateCheckError.rateLimited.errorDescription)
        XCTAssertNotNil(UpdateChecker.responseError(forStatusCode: 500))
        XCTAssertNil(UpdateChecker.responseError(forStatusCode: 200))
        XCTAssertNil(UpdateChecker.responseError(forStatusCode: 299))
        XCTAssertNotNil(UpdateChecker.responseError(forStatusCode: 301))
    }
}

// MARK: - UP2 — the tab strip is lazy, so some tabs have no measured frame

final class TabDragGeometryTests: XCTestCase {

    private let width: CGFloat = 120
    private lazy var order: [UUID] = (0..<20).map { _ in UUID() }

    private func allFrames() -> [UUID: CGRect] {
        var frames: [UUID: CGRect] = [:]
        for (index, id) in order.enumerated() {
            frames[id] = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: 30)
        }
        return frames
    }

    /// Only the tabs in `visible` keep a frame — what a `LazyHStack` publishes
    /// when the rest have never been built.
    private func frames(visible: ClosedRange<Int>) -> [UUID: CGRect] {
        allFrames().filter { key, _ in visible.contains(order.firstIndex(of: key)!) }
    }

    func testDraggingRightMovesThroughTheTabsItPasses() {
        let frames = allFrames()
        XCTAssertEqual(
            TabDragGeometry.targetIndex(order: order, frames: frames, dragged: order[8], translation: 0), 8
        )
        // Past tab 9's midpoint but not tab 10's.
        XCTAssertEqual(
            TabDragGeometry.targetIndex(order: order, frames: frames, dragged: order[8], translation: width), 9
        )
        XCTAssertEqual(
            TabDragGeometry.targetIndex(order: order, frames: frames, dragged: order[8], translation: 2.5 * width), 11
        )
    }

    func testDraggingLeftMovesThroughTheTabsItPasses() {
        let frames = allFrames()
        XCTAssertEqual(
            TabDragGeometry.targetIndex(order: order, frames: frames, dragged: order[8], translation: -width), 7
        )
        XCTAssertEqual(
            TabDragGeometry.targetIndex(order: order, frames: frames, dragged: order[8], translation: -3 * width), 5
        )
    }

    /// The reason this type exists: with the tabs outside the viewport
    /// unmeasured, the answer must be the one the fully measured bar gives.
    /// The old loop skipped every unmeasured tab, including the ones off the
    /// LEFT edge that the dragged tab is already past — so a drag in a window
    /// with 20 tabs and room for 10 landed several positions too far left.
    func testAnUnmeasuredTabToTheLeftStillCounts() {
        let visible = frames(visible: 6...15)
        for translation in stride(from: -2.0 * width, through: 2.0 * width, by: width / 2) {
            XCTAssertEqual(
                TabDragGeometry.targetIndex(order: order, frames: visible, dragged: order[8], translation: translation),
                TabDragGeometry.targetIndex(order: order, frames: allFrames(), dragged: order[8], translation: translation),
                "lazy and eager disagree at translation \(translation)"
            )
        }
    }

    func testADraggedTabWithNoFrameHasNoTarget() {
        XCTAssertNil(
            TabDragGeometry.targetIndex(order: order, frames: [:], dragged: order[0], translation: 0)
        )
    }
}

// MARK: - U4 — the Keybindings pane must tell the truth

@MainActor
final class KeybindingsPaneTests: XCTestCase {

    /// The pane listed "Add All Matches ⌘⌥⌃G". The binding is ⌘⌃⌥D
    /// (`SheepTextMenuCommands`, "Select All Occurrences"), and the palette
    /// title in `BuiltInCommands` said so — the pane was the one place that was
    /// wrong, because it is a hand-maintained copy of data that exists twice
    /// already.
    ///
    /// The pane cannot read the menu (a SwiftUI `Commands` body is not
    /// inspectable), but every row that names a registered command can be
    /// checked against that command's palette title, which carries the same
    /// shortcut. That is the copy that drifted, and this is what would have
    /// caught it.
    func testEveryPaneRowMatchesItsCommandsPaletteShortcut() {
        let registry = CommandRegistry()
        BuiltInCommands.registerAll(
            into: registry,
            workspace: WorkspaceStore(),
            documents: DocumentStore(),
            palette: CommandPaletteController()
        )

        for row in KeybindingsSettingsPane.rows {
            guard let commandID = row.commandID else { continue }
            guard let title = registry.entries[commandID]?.title else {
                XCTFail("\(row.command): no command registered as \(commandID)")
                continue
            }
            guard let inTitle = KeybindingsSettingsPane.trailingShortcut(of: title) else {
                XCTFail("\(commandID)'s palette title carries no shortcut: \(title)")
                continue
            }
            XCTAssertEqual(
                Set(inTitle), Set(row.shortcut),
                "\(row.command): pane says \(row.shortcut), \(commandID) says \(inTitle)"
            )
        }
    }

    /// The specific row that was wrong, pinned by value so a future edit that
    /// "fixes" it back cannot pass the set comparison above by changing both.
    func testAddAllMatchesIsCommandControlOptionD() {
        let row = KeybindingsSettingsPane.rows.first { $0.command == "Add All Matches" }
        XCTAssertEqual(row?.shortcut, "⌘⌃⌥D")
    }

    /// Modifier glyphs are written in different orders in the two places, so
    /// the comparison is by set. The extractor must still find the shortcut.
    func testTrailingShortcutExtraction() {
        XCTAssertEqual(
            KeybindingsSettingsPane.trailingShortcut(of: "Find: Find Next  ⌘G"), "⌘G"
        )
        XCTAssertEqual(
            KeybindingsSettingsPane.trailingShortcut(of: "Text: Delete Line  ⇧⌘K"), "⇧⌘K"
        )
        XCTAssertNil(KeybindingsSettingsPane.trailingShortcut(of: "Text: Sort Lines"))
    }
}
