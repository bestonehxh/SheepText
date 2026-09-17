//
//  AppStorageLocationTests.swift
//  The test host is the real app. These hold down that, under XCTest, nothing
//  the app persists reaches the user's own settings or Application Support.
//

import XCTest
@testable import SheepText

@MainActor
final class AppStorageLocationTests: XCTestCase {

    func testTheTestHostIsRecognised() {
        XCTAssertTrue(AppStorageLocation.isHostedByXCTest)
    }

    func testDefaultsAreAPerProcessSuiteNotTheAppDomain() {
        XCTAssertFalse(AppStorageLocation.defaults === UserDefaults.standard)
        let key = "sheeptext.tests.probe.\(UUID().uuidString)"
        AppStorageLocation.defaults.set("suite", forKey: key)
        defer { AppStorageLocation.defaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "a test write reached the user's domain")
    }

    /// The other direction: a suite that fell back to the app domain for reads
    /// would hand tests the user's own font size, auto-save switch and session
    /// — exactly the dependency that made tests pass on one machine only.
    func testDefaultsDoNotReadTheUsersSettings() {
        let key = "sheeptext.tests.probe.\(UUID().uuidString)"
        UserDefaults.standard.set("user", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        XCTAssertNil(AppStorageLocation.defaults.object(forKey: key), "the suite reads through to the user's domain")
    }

    func testPreferencesAndSessionWriteToTheSuite() throws {
        let preferences = AppPreferences()
        let before = preferences.editorFontSize
        defer { preferences.editorFontSize = before }
        preferences.editorFontSize = 31
        XCTAssertEqual(AppStorageLocation.defaults.double(forKey: "sheeptext.editor.fontSize"), 31)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-storage-\(UUID().uuidString).txt")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DocumentStore()
        _ = store.open(url: url, rememberRecent: false, showError: false)
        let session = AppStorageLocation.defaults.stringArray(forKey: "sheeptext.session.openFiles") ?? []
        XCTAssertTrue(session.contains(url.path), "the session was not persisted to the suite")
    }

    /// The isolation holds only while every site goes through
    /// `AppStorageLocation`. One direct `UserDefaults.standard` — the shape all
    /// 50 sites had before — puts the user's settings back in the tests' reach,
    /// so the sources are scanned for it, same idea as `LineEndingHygieneTests`.
    func testAppSourcesPersistOnlyThroughAppStorageLocation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SheepText", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Sources not reachable from \(root.path) — building from a different layout.")
        }
        var scanned = 0
        var violations: [String] = []
        for case let url as URL in walker
        where url.pathExtension == "swift" && url.lastPathComponent != "AppStorageLocation.swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if Self.bypassesAppStorageLocation(code) {
                    violations.append("\(url.lastPathComponent):\(index + 1): \(code)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 20, "expected to scan the app's sources, found \(scanned) files")
        XCTAssertTrue(violations.isEmpty, "Persistence that bypasses AppStorageLocation:\n" + violations.joined(separator: "\n"))
    }

    nonisolated static func bypassesAppStorageLocation(_ code: String) -> Bool {
        code.contains("UserDefaults.standard")
            || code.contains(".applicationSupportDirectory")
            || (code.contains("@AppStorage(") && !code.contains("store: AppStorageLocation.defaults"))
    }

    func testScannerCatchesEachShape() {
        XCTAssertTrue(Self.bypassesAppStorageLocation("let d = UserDefaults.standard"))
        XCTAssertTrue(Self.bypassesAppStorageLocation("fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)"))
        XCTAssertTrue(Self.bypassesAppStorageLocation(#"@AppStorage("k") private var v = 1"#))
        XCTAssertFalse(Self.bypassesAppStorageLocation(#"@AppStorage("k", store: AppStorageLocation.defaults) private var v = 1"#))
        XCTAssertFalse(Self.bypassesAppStorageLocation("let d = AppStorageLocation.defaults"))
    }

    func testApplicationSupportIsATemporaryDirectory() {
        let path = AppStorageLocation.applicationSupport.standardizedFileURL.path
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertTrue(path.hasPrefix(temp), "\(path) is not under \(temp)")
        XCTAssertEqual(PluginPaths.appSupport, AppStorageLocation.applicationSupport)
    }
}

// MARK: - Leaving the sandbox (3.7)

/// 3.6 and earlier ran sandboxed, so everything the user has — settings, the
/// remembered tabs, recents, drafts and plugins — sits inside
/// `~/Library/Containers/Bestchaan.SheepText/Data`. An unsandboxed build reads
/// none of that, so without this migration the app comes up looking wiped.
final class SandboxContainerMigrationTests: XCTestCase {

    private var root: URL!
    private var container: URL!
    private var applicationSupport: URL!
    private var suiteName: String!
    private var destination: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-migration-\(UUID().uuidString)", isDirectory: true)
        container = root.appendingPathComponent("Container/Data", isDirectory: true)
        applicationSupport = root.appendingPathComponent("Application Support/SheepText", isDirectory: true)
        suiteName = "Bestchaan.SheepText.migration.\(UUID().uuidString)"
        destination = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func seedContainer(preferences: [String: Any], files: [String: String]) throws {
        let fm = FileManager.default
        let prefs = container.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: preferences, format: .binary, options: 0
        )
        try data.write(to: prefs.appendingPathComponent("Bestchaan.SheepText.plist"))

        let support = container
            .appendingPathComponent("Library/Application Support/SheepText", isDirectory: true)
        for (path, contents) in files {
            let url = support.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func migrate() -> Bool {
        AppStorageLocation.migrateFromSandboxContainer(
            container: container,
            bundleID: "Bestchaan.SheepText",
            into: destination,
            applicationSupport: applicationSupport
        )
    }

    func testSettingsAndFilesComeAcrossAndTheMarkerIsSet() throws {
        try seedContainer(
            preferences: [
                "sheeptext.recentFiles": ["/Users/someone/Documents/a.txt"],
                "sheeptext.appearance.chromeStyle": "glass",
            ],
            files: ["Drafts/draft-1.json": "{}", "Plugins/hello/plugin.json": "{}"]
        )

        XCTAssertTrue(migrate())

        XCTAssertEqual(
            destination.array(forKey: "sheeptext.recentFiles") as? [String],
            ["/Users/someone/Documents/a.txt"]
        )
        XCTAssertEqual(destination.string(forKey: "sheeptext.appearance.chromeStyle"), "glass")
        XCTAssertTrue(destination.bool(forKey: AppStorageLocation.sandboxMigrationMarkerKey))

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: applicationSupport.appendingPathComponent("Drafts/draft-1.json").path))
        XCTAssertTrue(fm.fileExists(atPath: applicationSupport.appendingPathComponent("Plugins/hello/plugin.json").path))
        // The container is left exactly where it was, so this is undoable.
        XCTAssertTrue(fm.fileExists(atPath: container.path))
    }

    func testASecondLaunchDoesNotOverwriteNewerSettings() throws {
        try seedContainer(preferences: ["sheeptext.editor.fontSize": 13.0], files: [:])
        XCTAssertTrue(migrate())

        destination.set(18.0, forKey: "sheeptext.editor.fontSize")
        XCTAssertFalse(migrate(), "the migration must run once, not on every launch")
        XCTAssertEqual(destination.double(forKey: "sheeptext.editor.fontSize"), 18.0)
    }

    func testAFileAlreadyInTheNewLocationIsKept() throws {
        try seedContainer(preferences: [:], files: ["Drafts/draft-1.json": "from the container"])
        let existing = applicationSupport.appendingPathComponent("Drafts/draft-1.json")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "newer".write(to: existing, atomically: true, encoding: .utf8)

        XCTAssertTrue(migrate())
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "newer")
    }

    func testNoContainerMeansNothingToDo() {
        XCTAssertFalse(migrate())
        XCTAssertFalse(destination.bool(forKey: AppStorageLocation.sandboxMigrationMarkerKey))
    }

    func testTheShippingBuildIsNotSandboxedSoNoBookmarkIsNeeded() {
        // The bookmark table only exists to work around the sandbox; if a
        // build ever goes back inside one, prepare() must start storing again.
        XCTAssertFalse(AppStorageLocation.isSandboxed)
        let url = URL(fileURLWithPath: "/Users/someone/Documents/a.txt")
        XCTAssertEqual(
            SecurityScopedResourceAccess.prepare(
                url,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
                shouldRemember: true
            ),
            url
        )
    }
}
