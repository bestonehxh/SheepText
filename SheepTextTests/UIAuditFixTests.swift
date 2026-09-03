//
//  UIAuditFixTests.swift
//  Regression tests for the app / UI / plugin findings of the Sept 2026 audit.
//  One test (or group) per finding id; the id is named in each test's comment
//  so a failure points straight back at what it is protecting.
//

import AppKit
import JavaScriptCore
import SwiftUI
import XCTest
@testable import SheepText

// MARK: - U9 — UpdateChecker.isNewer

final class UpdateCheckerVersionTests: XCTestCase {

    /// The bug: `split(separator: ".").compactMap { Int($0) }` DROPPED any
    /// component that did not parse whole, which shifts every later component
    /// left. "1.3.5-beta.2" became [1, 3, 2] — read as 1.3.2, i.e. a downgrade
    /// — and "1.3.5 (17)" became [1, 3], read as 1.3.0.
    func testPreReleaseTagIsNotNewerThanItsRelease() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5-beta.2", than: "1.3.5"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5+build.9", than: "1.3.5"))
    }

    func testBuildNumberSuffixIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5 (17)", than: "1.3.5"))
    }

    func testComponentsCompareNumericallyNotLexically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.0", than: "1.10.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3", than: "1.3.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.3.1", than: "1.3"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.5", than: "1.3.5"))
    }

    /// A component that is not a number at all must become 0 rather than
    /// vanish, so the positions of the components after it do not move.
    func testUnparseableComponentDoesNotShiftLaterComponents() {
        XCTAssertTrue(UpdateChecker.isNewer("1.x.9", than: "1.0.8"))
        XCTAssertFalse(UpdateChecker.isNewer("1.x.7", than: "1.0.8"))
    }

    // MARK: U3 — launch-check throttle

    func testAutomaticCheckIsSkippedWhenPreferenceIsOff() {
        XCTAssertFalse(UpdateChecker.isAutomaticCheckDue(enabled: false, lastCheck: nil, now: Date()))
    }

    func testFirstEverAutomaticCheckIsDue() {
        XCTAssertTrue(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: nil, now: Date()))
    }

    func testAutomaticCheckIsThrottledForTwentyFourHours() {
        let now = Date()
        let hourAgo = now.addingTimeInterval(-3600)
        XCTAssertFalse(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: hourAgo, now: now))

        let dayAgo = now.addingTimeInterval(-UpdateChecker.automaticCheckInterval - 1)
        XCTAssertTrue(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: dayAgo, now: now))
    }

    /// A clock correction can leave a timestamp in the future. That must not
    /// mean "never check again".
    func testFutureTimestampIsTreatedAsDue() {
        let now = Date()
        XCTAssertTrue(
            UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(600), now: now)
        )
    }
}

// MARK: - U7 — FSBridge scope

@MainActor
final class FSBridgeScopeTests: XCTestCase {

    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var pluginFolder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fsbridge-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        pluginFolder = base.appendingPathComponent("plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func bridge() -> FSBridge {
        FSBridge(pluginFolder: pluginFolder, workspaceRoot: root)
    }

    func testFileInsideTheWorkspaceRootIsReadable() throws {
        let file = root.appendingPathComponent("inside.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(bridge().readFile(file.path), "hello")
        XCTAssertTrue(bridge().exists(file.path))
    }

    /// The bug: `url.path.hasPrefix(root.path)` is a STRING test, so a sibling
    /// directory whose name merely starts with the root's name passed it —
    /// "/proj-secrets" is inside "/proj" as far as `hasPrefix` is concerned.
    func testSiblingDirectoryWithTheRootAsANamePrefixIsRejected() throws {
        let sibling = root.deletingLastPathComponent().appendingPathComponent("root-x", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let secret = sibling.appendingPathComponent("secret.txt")
        try "nope".write(to: secret, atomically: true, encoding: .utf8)

        XCTAssertFalse(bridge().exists(secret.path))
        XCTAssertEqual(bridge().readFile(secret.path), "")
    }

    /// The bug: the check never resolved symlinks, so a link planted inside the
    /// workspace read straight through to whatever it pointed at.
    func testSymlinkInsideTheRootPointingOutsideIsRejected() throws {
        let outsideDir = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let secret = outsideDir.appendingPathComponent("secret.txt")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)

        let link = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        XCTAssertFalse(bridge().exists(link.path))
        XCTAssertEqual(bridge().readFile(link.path), "")
    }

    /// `..` must not walk out either, whether or not a symlink is involved.
    func testParentTraversalOutOfTheRootIsRejected() throws {
        let outsideDir = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let secret = outsideDir.appendingPathComponent("secret.txt")
        try "top secret".write(to: secret, atomically: true, encoding: .utf8)

        XCTAssertFalse(bridge().exists(root.appendingPathComponent("../outside/secret.txt").path))
        XCTAssertEqual(bridge().readFile("../outside/secret.txt"), "")
    }

    func testWritingOutsideTheRootFails() throws {
        let outsideDir = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let target = outsideDir.appendingPathComponent("written.txt")

        XCTAssertFalse(bridge().writeFile(target.path, "x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testPluginFolderIsAlwaysAllowed() throws {
        let file = pluginFolder.appendingPathComponent("own.txt")
        XCTAssertTrue(bridge().writeFile(file.path, "mine"))
        XCTAssertEqual(bridge().readFile(file.path), "mine")
    }
}

// MARK: - U6 / U2 — plugin host lifetime and loading

@MainActor
final class PluginHostLifecycleTests: XCTestCase {

    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    private func writePlugin(_ source: String) throws -> PluginManifest {
        try source.write(
            to: folder.appendingPathComponent("src/index.js"),
            atomically: true,
            encoding: .utf8
        )
        let manifestJSON = """
        {
          "id": "test-plugin",
          "name": "Test Plugin",
          "version": "1.0.0",
          "main": "src/index.js",
          "activationEvents": ["onStartup"],
          "permissions": ["fs"],
          "contributes": {
            "commands": [{ "id": "test.declared", "title": "Test: Declared" }],
            "keybindings": [{ "command": "test.declared", "key": "cmd+alt+r" }]
          }
        }
        """
        let url = folder.appendingPathComponent("plugin.json")
        try manifestJSON.write(to: url, atomically: true, encoding: .utf8)
        return try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))
    }

    /// U13: the manifest no longer has `permissions` or `contributes.keybindings`
    /// (nothing read either one). A plugin.json that still declares them must
    /// keep loading — `JSONDecoder` ignores unknown keys.
    func testManifestStillDecodesWithTheRemovedFields() throws {
        let manifest = try writePlugin("module.exports = { activate: function () {} };")
        XCTAssertEqual(manifest.id, "test-plugin")
        XCTAssertEqual(manifest.contributes?.commands?.count, 1)
    }

    /// U2: the whole subsystem was dead at runtime because nothing ever built a
    /// PluginManager. This drives the same path a real load takes — manifest,
    /// host, activate, command registration — against a temp folder.
    func testActivatingAPluginRegistersItsDeclaredAndDynamicCommands() throws {
        let manifest = try writePlugin("""
        function activate(context) {
          commands.register('test.dynamic', function () { globalThis.__ran = true; });
        }
        module.exports = { activate: activate };
        """)

        let registry = CommandRegistry()
        let host = PluginHost(
            folder: folder,
            manifest: manifest,
            commands: registry,
            workspace: WorkspaceStore()
        )
        host.activate()

        XCTAssertNotNil(registry.entries["test.declared"], "manifest-declared command missing")
        XCTAssertNotNil(registry.entries["test.dynamic"], "runtime-registered command missing")
        XCTAssertEqual(registry.entries["test.declared"]?.source, .plugin("test-plugin"))

        registry.execute("test.dynamic")

        host.deactivate()
        XCTAssertNil(registry.entries["test.declared"], "deactivate must sweep the plugin's commands")
        XCTAssertNil(registry.entries["test.dynamic"])
    }

    /// U6: `CommandsBridge` stored raw `JSValue` handlers. A JSValue retains its
    /// JSContext; the context retains the exported bridge; the bridge retained
    /// the handlers — a cycle through the JS heap that nothing could collect, so
    /// every plugin reload leaked a whole JSContext and virtual machine.
    ///
    /// The handlers are `JSManagedValue`s now, so this weak reference has to go
    /// to nil once the last strong reference is dropped.
    func testRegisteredHandlerDoesNotRetainItsJSContext() {
        weak var weakContext: JSContext?
        weak var weakBridge: CommandsBridge?

        autoreleasepool {
            let context = JSContext(virtualMachine: JSVirtualMachine())!
            let bridge = CommandsBridge(host: nil)
            context.setObject(bridge, forKeyedSubscript: "commands" as NSString)
            context.evaluateScript("commands.register('x', function () { return 1; });")

            weakContext = context
            weakBridge = bridge
            XCTAssertEqual(bridge.getAll().first?["id"], "x", "handler was not stored at all")
        }

        XCTAssertNil(weakBridge, "CommandsBridge leaked — the JSContext still holds it")
        XCTAssertNil(weakContext, "JSContext leaked — the handler JSValue still retains it")
    }

    /// The other half of U6: after a reload the old host must actually go away.
    func testHostIsReleasedAfterDeactivate() throws {
        let manifest = try writePlugin("""
        function activate(context) {
          commands.register('test.dynamic', function () {});
        }
        module.exports = { activate: activate };
        """)
        let registry = CommandRegistry()
        weak var weakHost: PluginHost?

        autoreleasepool {
            let host = PluginHost(
                folder: folder,
                manifest: manifest,
                commands: registry,
                workspace: WorkspaceStore()
            )
            host.activate()
            weakHost = host
            host.deactivate()
        }

        XCTAssertNil(weakHost, "PluginHost survived deactivate — reloadAll would leak one per reload")
    }
}

// MARK: - U4 — save commands act on ONE document

@MainActor
final class SaveTargetResolutionTests: XCTestCase {

    /// With no editor focused, the target is the active tab — the behaviour
    /// callers already relied on.
    func testTargetFallsBackToTheActiveDocument() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        XCTAssertEqual(BuiltInCommands.saveTargetDocumentID(documents), doc.id)
    }

    /// `prepareSave` no longer trims (auto save must never rewrite the user's
    /// text), so a manual save has to. A background tab has no text view, and
    /// the trim still has to happen for it — Save All writes it too.
    func testTrimAppliesToADocumentWithNoLiveEditor() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        doc.lineEnding = .lf
        doc.autoTrimTrailingWhitespace = true
        doc.text = "a   \nb\t\nc"

        BuiltInCommands.trimDocumentIfNeeded(doc.id, in: documents)

        XCTAssertEqual(doc.text, "a\nb\nc")
    }

    func testTrimIsSkippedWhenTheOptionIsOff() {
        let documents = DocumentStore()
        let doc = documents.newUntitled()
        doc.autoTrimTrailingWhitespace = false
        doc.text = "a   \nb"

        BuiltInCommands.trimDocumentIfNeeded(doc.id, in: documents)

        XCTAssertEqual(doc.text, "a   \nb")
    }

    func testSaveAllTrimsEveryDirtyDocument() {
        let documents = DocumentStore()
        let first = documents.newUntitled()
        let second = documents.newUntitled()
        for doc in [first, second] {
            doc.lineEnding = .lf
            doc.autoTrimTrailingWhitespace = true
            doc.text = "x   "
            doc.isDirty = true
        }

        BuiltInCommands.trimAllDirtyDocumentsIfNeeded(in: documents)

        XCTAssertEqual(first.text, "x")
        XCTAssertEqual(second.text, "x", "Save All used to trim only the focused editor's document")
    }
}

// MARK: - U18 — editor-appearance notification coalescing

@MainActor
final class EditorAppearanceCoalescingTests: XCTestCase {

    /// Every observer of `.editorAppearanceDidChange` clears its highlight cache
    /// and re-highlights the whole document. Dragging the font-size slider from
    /// 9 pt to 36 pt posted it 27 times — 27 full re-parses for one gesture.
    ///
    /// Leading + trailing: the first step is still immediate, everything inside
    /// the coalescing window collapses into one trailing post.
    func testASliderDragCollapsesIntoTwoNotifications() {
        let preferences = AppPreferences()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .editorAppearanceDidChange, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for size in 9...35 {
            preferences.editorFontSize = Double(size)
        }
        XCTAssertEqual(posts, 1, "the first change must still be immediate")

        let settled = expectation(description: "coalescing window elapsed")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppPreferences.editorAppearanceCoalescingWindow * 3
        ) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(posts, 2, "27 slider steps must cost 2 notifications, not 27")
    }

    /// A single change (a checkbox, a font pick) must still be immediate and
    /// must not fire a second time when the window closes.
    func testASingleChangePostsExactlyOnce() {
        let preferences = AppPreferences()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .editorAppearanceDidChange, object: nil, queue: .main
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        preferences.showsLineNumbers.toggle()
        XCTAssertEqual(posts, 1)

        let settled = expectation(description: "coalescing window elapsed")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AppPreferences.editorAppearanceCoalescingWindow * 3
        ) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(posts, 1, "the trailing edge must not duplicate a lone change")
    }
}

// MARK: - U21 — file tree flattening

@MainActor
final class FileTreeFlatteningTests: XCTestCase {

    private func node(_ path: String, isDirectory: Bool, children: [FileNode]? = nil) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path), isDirectory: isDirectory, children: children)
    }

    /// The flattened list must be the depth-first order the nested VStacks
    /// produced, with the same levels — this is what makes one LazyVStack a
    /// drop-in for the recursive one.
    func testFlattenProducesDepthFirstRowsWithLevels() {
        let tree = [
            node("/w/src", isDirectory: true, children: [
                node("/w/src/a.swift", isDirectory: false),
                node("/w/src/deep", isDirectory: true, children: [
                    node("/w/src/deep/b.swift", isDirectory: false)
                ])
            ]),
            node("/w/README.md", isDirectory: false)
        ]

        let expanded: Set<URL> = [
            URL(fileURLWithPath: "/w/src").standardizedFileURL,
            URL(fileURLWithPath: "/w/src/deep").standardizedFileURL
        ]
        let rows = FileTreeView.flatten(tree, expandedFolders: expanded)

        XCTAssertEqual(rows.map(\.node.url.lastPathComponent),
                       ["src", "a.swift", "deep", "b.swift", "README.md"])
        XCTAssertEqual(rows.map(\.level), [0, 1, 1, 2, 0])
    }

    func testCollapsedFoldersContributeNoRows() {
        let tree = [
            node("/w/src", isDirectory: true, children: [
                node("/w/src/a.swift", isDirectory: false)
            ])
        ]
        let rows = FileTreeView.flatten(tree, expandedFolders: [])
        XCTAssertEqual(rows.map(\.node.url.lastPathComponent), ["src"])
    }

    func testRowIdentitiesAreUnique() {
        let tree = [
            node("/w/src", isDirectory: true, children: [
                node("/w/src/a.swift", isDirectory: false),
                node("/w/src/b.swift", isDirectory: false)
            ])
        ]
        let rows = FileTreeView.flatten(
            tree,
            expandedFolders: [URL(fileURLWithPath: "/w/src").standardizedFileURL]
        )
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}

// MARK: - S4 — SQL numeric literals

@MainActor
final class SQLNumberHighlightTests: XCTestCase {

    /// `#match?` predicates are compiled with `NSRegularExpression`, where `%d`
    /// is a literal percent followed by a d — a Lua character class that never
    /// matches a digit. Both SQL number patterns were therefore dead and every
    /// numeric literal kept the earlier `(literal) @string` capture, rendering
    /// green instead of orange.
    func testSQLIntegerLiteralIsColouredAsANumberNotAString() throws {
        let text = "SELECT 42, 3.14, 'text' FROM t;"
        let highlighted = try XCTUnwrap(
            SyntaxEngine.shared.highlightImmediately(text: text, language: "sql", isDark: true),
            "SQL grammar or queries did not load"
        )

        let ns = text as NSString
        let numberColour = try colour(in: highlighted, at: ns.range(of: "42"))
        let floatColour = try colour(in: highlighted, at: ns.range(of: "3.14"))
        let stringColour = try colour(in: highlighted, at: ns.range(of: "'text'"))

        // One Dark "number" is #D19A66; "string" is #98C379.
        XCTAssertEqual(hex(numberColour), "D19A66", "42 is not painted as a number")
        XCTAssertEqual(hex(floatColour), "D19A66", "3.14 is not painted as a number")
        XCTAssertNotEqual(hex(numberColour), hex(stringColour))
    }

    private func colour(in string: NSAttributedString, at range: NSRange) throws -> NSColor {
        XCTAssertNotEqual(range.location, NSNotFound)
        let attributes = string.attributes(at: range.location, effectiveRange: nil)
        return try XCTUnwrap(attributes[.foregroundColor] as? NSColor, "no colour at \(range)")
    }

    private func hex(_ colour: NSColor) -> String {
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        return String(
            format: "%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
