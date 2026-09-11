//
//  AppStorageLocation.swift
//  SheepText
//
//  Where the app keeps what it persists: preferences, the session, recents,
//  security-scoped bookmarks, drafts, backups and plugins.
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
        guard isHostedByXCTest else { return .standard }
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
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("SheepText", isDirectory: true)
    }()

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
