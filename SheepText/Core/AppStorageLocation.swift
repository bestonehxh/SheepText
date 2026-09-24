//
//  AppStorageLocation.swift
//  SheepText
//
//  Where the app keeps what it persists: preferences, the session, recents,
//  security-scoped bookmarks, drafts and backups.
//

import Foundation

/// The one place that decides where persistent state lives.
///
/// SheepTextTests is hosted inside SheepText.app — same bundle id, same sandbox
/// container, same `UserDefaults.standard`. Every test that went near
/// persistence therefore read and wrote the user's real settings: an appearance
/// test left the editor at 35 pt with no gutter (3.1), a session test replaced
/// the tabs the user reopens with a temp file (3.2's release run), and
/// `restoreSessionTabs` picked up a real unsaved draft and failed on the user's
/// machine only. Snapshot/restore in each test is not enough — Xcode runs the
/// test plan in parallel processes, and the test host is the full app, which
/// restores and persists a session on launch before any test starts.
///
/// So when the process is hosted by XCTest, everything goes somewhere private
/// to that process: a defaults suite of its own and a temporary directory in
/// place of Application Support. The app never takes that branch.
nonisolated enum AppStorageLocation {
    /// XCTest sets these in the environment of the process it hosts tests in.
    static let isHostedByXCTest: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()

    /// Prefix of the per-process defaults suites used under XCTest.
    static let testSuitePrefix = "Bestchaan.SheepText.tests."

    /// Every app read and write of its own settings goes through this — never
    /// `UserDefaults.standard` directly. (AppKit's own keys, such as
    /// `NSAutomaticPeriodSubstitutionEnabled`, still belong in `.standard`:
    /// that is the domain AppKit reads.)
    ///
    /// `nonisolated(unsafe)`: `UserDefaults` is documented thread-safe but not
    /// marked `Sendable`, and this is a `let` initialised once.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isHostedByXCTest else {
            // Before the first read, never after: 3.7 left the sandbox, and
            // everything the user had is still inside the old container.
            _ = didMigrateFromSandboxContainer
            return .standard
        }
        removeStaleTestSuites()
        let name = testSuitePrefix + String(ProcessInfo.processInfo.processIdentifier)
        // Start empty: a pid can be reused, and a test must not see what an
        // earlier run left behind any more than it may see the user's.
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()

    /// `~/Library/Application Support/SheepText` (inside the sandbox
    /// container), or a fresh temporary directory under XCTest.
    static let applicationSupport: URL = {
        let fm = FileManager.default
        if isHostedByXCTest {
            let dir = fm.temporaryDirectory.appendingPathComponent(
                "SheepText-tests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            try? fm.removeItem(at: dir)
            return dir
        }
        _ = didMigrateFromSandboxContainer
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("SheepText", isDirectory: true)
    }()

    // MARK: - Leaving the sandbox (3.7)

    /// True while the process runs inside an App Sandbox container.
    ///
    /// SheepText shipped sandboxed up to 3.6. macOS only lets a sandboxed app
    /// read files the user picked in a panel, so Open Recent depended on a
    /// security-scoped bookmark per file and dead-ended whenever one was
    /// missing. 3.7 drops the sandbox: every path the user can read, SheepText
    /// can open. Nothing in the app may assume either answer — the tests run
    /// in whatever the host was built as.
    static let isSandboxed: Bool = {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }()

    /// Set once in the destination domain when the container has been copied
    /// out, so a later launch does not overwrite newer settings with the old
    /// container's copy of them.
    static let sandboxMigrationMarkerKey = "sheeptext.migratedFromSandboxContainer"

    /// Keys the sandbox needed and an unsandboxed app cannot use.
    ///
    /// These two dictionaries hold app-scoped security-scoped bookmark blobs —
    /// on this machine 449 KB of them, essentially the whole preferences
    /// domain. Since 3.7 `prepare`, `restore` and `remember` all short-circuit
    /// on `!isSandboxed`, so nothing reads them, nothing writes them, and
    /// nothing would ever prune them; `cfprefsd` reads and caches the domain at
    /// every launch. They are not even valid for a non-sandboxed process.
    /// Named by string rather than through `SecurityScopedResourceAccess` so
    /// this stays true if that type is one day deleted.
    static let obsoleteSandboxKeys: Set<String> = [
        "sheeptext.securityScoped.fileBookmarks",
        "sheeptext.securityScoped.workspaceBookmarks"
    ]

    /// The old container's Data directory, whether or not it still exists.
    static var sandboxContainerData: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "Bestchaan.SheepText"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data", isDirectory: true)
    }

    /// Forced from `defaults` and `applicationSupport`, so it runs before the
    /// first read of either and exactly once.
    private static let didMigrateFromSandboxContainer: Bool = {
        guard !isHostedByXCTest, !isSandboxed else { return false }
        return migrateFromSandboxContainer(
            container: sandboxContainerData,
            bundleID: Bundle.main.bundleIdentifier ?? "Bestchaan.SheepText",
            into: .standard,
            applicationSupport: FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("SheepText", isDirectory: true)
        )
    }()

    /// Copy a sandbox container's settings and Application Support tree into
    /// the plain user-domain locations an unsandboxed app reads.
    ///
    /// Settings are copied key by key and overwrite what is in the destination.
    /// Files are copied item by item and never overwrite. The two halves have
    /// opposite policies on purpose, and the reason is the same for both: the
    /// container is the only state the user has. This bundle id has only ever
    /// been sandboxed (`ENABLE_APP_SANDBOX = YES` arrived with the BeeSheep →
    /// SheepText rename), so nothing ever wrote the destination domain or
    /// `~/Library/Application Support/SheepText` before 3.7 — a value there is
    /// either absent or something this migration itself put there on an
    /// earlier, interrupted run. Overwriting a setting is then harmless, and
    /// NOT overwriting a file is what makes an interrupted run safe to repeat.
    /// (The previous comment claimed the destination held "years stale"
    /// pre-sandbox settings. There are none.)
    ///
    /// **One way.** The marker lives in the destination domain, which a
    /// sandboxed 3.6 cannot see, so running 3.6 again after 3.7 writes to the
    /// container and nothing brings it back. The container is left untouched,
    /// so that is recoverable by hand; it is not recovered automatically.
    ///
    /// The container's security-scoped bookmarks are deliberately NOT copied:
    /// see `obsoleteSandboxKeys`.
    @discardableResult
    static func migrateFromSandboxContainer(
        container: URL,
        bundleID: String,
        into destination: UserDefaults,
        applicationSupport: URL?
    ) -> Bool {
        let fm = FileManager.default
        guard !destination.bool(forKey: sandboxMigrationMarkerKey),
              fm.fileExists(atPath: container.path)
        else { return false }

        let plist = container
            .appendingPathComponent("Library/Preferences/\(bundleID).plist")
        if let data = try? Data(contentsOf: plist),
           let stored = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil
           ) as? [String: Any] {
            for (key, value) in stored
            where key != sandboxMigrationMarkerKey && !obsoleteSandboxKeys.contains(key) {
                destination.set(value, forKey: key)
            }
            // Also from an earlier migration, before this skipped them.
            for key in obsoleteSandboxKeys { destination.removeObject(forKey: key) }
        }

        if let applicationSupport {
            let source = container
                .appendingPathComponent("Library/Application Support/SheepText", isDirectory: true)
            copyContents(of: source, into: applicationSupport)
        }

        destination.set(true, forKey: sandboxMigrationMarkerKey)
        return true
    }

    /// Recursive copy that keeps whatever is already at the destination.
    private static func copyContents(of source: URL, into destination: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return }
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                copyContents(of: from, into: to)
            } else if !fm.fileExists(atPath: to.path) {
                try? fm.copyItem(at: from, to: to)
            }
        }
    }

    /// Suites whose test process is gone. Each test process makes one, and a
    /// test host that is killed rather than quit never cleans up after itself.
    private static func removeStaleTestSuites() {
        let fm = FileManager.default
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: preferences.path) else { return }
        for file in names where file.hasPrefix(testSuitePrefix) && file.hasSuffix(".plist") {
            let pidText = file.dropFirst(testSuitePrefix.count).dropLast(".plist".count)
            guard let pid = Int32(pidText), kill(pid, 0) != 0, errno == ESRCH else { continue }
            UserDefaults().removePersistentDomain(forName: String(file.dropLast(".plist".count)))
            try? fm.removeItem(at: preferences.appendingPathComponent(file))
        }
    }
}
