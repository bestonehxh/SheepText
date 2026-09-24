//
//  PerfHarnessUITests.swift
//  Workloads for the chrome findings of the Sept 17 2026 audit (UP1, UP2).
//
//  Both drive a real `NSHostingView` in a real window, because what these
//  changes affect is how much SwiftUI re-evaluates when one observable
//  property moves — which does not exist outside a hosted view. Both compile
//  against the pre-fix API (neither view's initializer changed), so the
//  orchestrator can run them on the old commit.
//
//  Caveat that belongs with the numbers: SwiftUI coalesces its updates on the
//  run loop, so these measure "mutate, then force layout" and are noisier than
//  the pure-Swift workloads in the other PerfHarness classes.
//

import AppKit
import SwiftUI
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessUITests: XCTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 60),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func host<V: View>(_ view: V, height: CGFloat) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: height)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    /// UP1: the caret readout and the six badge menus used to be one body, so
    /// every keystroke and every arrow key rebuilt the ~30-entry language menu.
    func testPerfStatusBarCaretMoves() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        doc.text = String(repeating: "vlan 10 name users\n", count: 200)
        let cursor = CursorState()
        let preferences = AppPreferences()

        let hosting = host(
            StatusBarView()
                .environment(documents)
                .environment(cursor)
                .environment(preferences),
            height: 22
        )

        PerfHarness.measure("ui_statusbar_caret_200", samples: 5, iterations: 1) {
            for step in 1...200 {
                cursor.line = step
                cursor.column = step % 80 + 1
                cursor.totalCount = doc.text.utf16.count
                hosting.layoutSubtreeIfNeeded()
            }
            return cursor.line
        }
    }

    /// UP2: 100 tabs in a plain `HStack` meant 100 chip bodies built, laid out
    /// and measured through a `GeometryReader` preference on every pass.
    func testPerfTabBarHundredTabsActivationChanges() {
        let documents = DocumentStore()
        let workspace = WorkspaceStore()
        let preferences = AppPreferences()
        for _ in 0..<100 { _ = documents.newUntitled() }
        let ids = documents.documents.map(\.id)

        let hosting = host(
            TabBarView()
                .environment(documents)
                .environment(workspace)
                .environment(preferences),
            height: SheepTextChromeMetrics.topBarHeight
        )

        PerfHarness.measure("ui_tabbar_100_activate", samples: 5, iterations: 1) {
            for id in ids {
                documents.activeDocumentID = id
                hosting.layoutSubtreeIfNeeded()
            }
            return documents.documents.count
        }
    }
}
