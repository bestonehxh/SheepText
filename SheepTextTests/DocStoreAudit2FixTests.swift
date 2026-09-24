//
//  DocStoreAudit2FixTests.swift
//  Regressions for the second persistence / file-IO audit (17 September 2026).
//
//  One test (or one tight group) per finding ID. Each was written against the
//  unfixed code and watched to fail first.
//

import AppKit
import XCTest
@testable import SheepText

// MARK: - D1 / D7 / D10 — what an atomic replace destroys

final class FileWriteIdentityTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A read-only directory from the D10 case would defeat the cleanup.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for name in contents {
                _ = chmod(base.appendingPathComponent(name).path, 0o700)
            }
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func extendedAttributeNames(of url: URL) -> Set<String> {
        let length = listxattr(url.path, nil, 0, 0)
        guard length > 0 else { return [] }
        var buffer = [CChar](repeating: 0, count: length)
        let written = listxattr(url.path, &buffer, length, 0)
        guard written > 0 else { return [] }
        var names: Set<String> = []
        var start = 0
        for index in 0..<written where buffer[index] == 0 {
            if index > start {
                names.insert(String(cString: Array(buffer[start..<index]) + [0]))
            }
            start = index + 1
        }
        return names
    }

    private func setExtendedAttribute(_ name: String, on url: URL) {
        let bytes = Array("sheeptext-test".utf8)
        XCTAssertEqual(setxattr(url.path, name, bytes, bytes.count, 0, 0), 0)
    }

    /// D1: `.atomic` is mkstemp + rename, and a rename REPLACES a symlink with
    /// an ordinary file. `~/.zshrc` stopped being a link to the dotfiles repo,
    /// and the repo kept the old text.
    func testSavingThroughASymlinkWritesTheRealFileAndKeepsTheLink() throws {
        let real = base.appendingPathComponent("real.txt")
        let link = base.appendingPathComponent("link.txt")
        try "original\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try TextFileIO.writeData(Data("written through the link\n".utf8), to: link)

        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
            "the symlink was replaced by a regular file"
        )
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "written through the link\n")
    }

    /// The same thing one level up: the file is reached through a symlinked
    /// DIRECTORY, which is what a dotfiles or shared-config layout usually is.
    func testSavingThroughASymlinkedDirectoryWritesTheRealFile() throws {
        let realDirectory = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        let real = realDirectory.appendingPathComponent("body.txt")
        try "original\n".write(to: real, atomically: true, encoding: .utf8)

        let linkedDirectory = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)

        try TextFileIO.writeData(Data("new\n".utf8), to: linkedDirectory.appendingPathComponent("body.txt"))

        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: linkedDirectory.path))
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "new\n")
    }

    /// D1, second half: an atomic replace always splits a hard-linked pair —
    /// the file the user edited keeps the new bytes and its twin silently keeps
    /// the old ones. A file with more than one link is written in place.
    func testSavingAHardLinkedFileKeepsThePairTogether() throws {
        let first = base.appendingPathComponent("h1.txt")
        let second = base.appendingPathComponent("h2.txt")
        try "shared\n".write(to: first, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: first, to: second)

        try TextFileIO.writeData(Data("changed\n".utf8), to: first)

        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "changed\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "changed\n",
                       "the hard link was split by the save")
    }

    /// D7: the rename leaves the original's extended attributes behind — Finder
    /// tags and comments, `com.apple.TextEncoding`, quarantine. Open a tagged
    /// file, ⌘S, and Finder shows no tag.
    func testSavingPreservesExtendedAttributesAndPOSIXMode() throws {
        let file = base.appendingPathComponent("tagged.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)
        setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", on: file)
        XCTAssertEqual(chmod(file.path, 0o640), 0)

        try TextFileIO.writeData(Data("two\n".utf8), to: file)

        XCTAssertTrue(
            extendedAttributeNames(of: file).contains("com.apple.metadata:_kMDItemUserTags"),
            "the save dropped the file's extended attributes"
        )
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o640)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two\n")
    }

    /// D10: a writable file inside a directory the user cannot write fails at
    /// `mktemp`, not at the file — so the save failed outright with a message
    /// about a temporary file. A plain write succeeds there.
    func testSavingIntoANonWritableDirectorySucceeds() throws {
        let directory = base.appendingPathComponent("rodir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("f.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(directory.path, 0o500), 0)
        defer { _ = chmod(directory.path, 0o700) }

        try TextFileIO.writeData(Data("after\n".utf8), to: file)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
    }

    /// A file that does not exist yet (Save As, and every Replace in Files
    /// backup) still has to be created.
    func testWritingANewFileCreatesIt() throws {
        let file = base.appendingPathComponent("brand-new.txt")
        try TextFileIO.writeData(Data("hello\n".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello\n")
    }

    /// Shortening a file must not leave the tail of the old contents behind —
    /// the in-place branches have to truncate.
    func testAShorterWriteTruncates() throws {
        let file = base.appendingPathComponent("shrink.txt")
        let twin = base.appendingPathComponent("shrink-twin.txt")
        try "LONG LONG LONG LONG\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: file, to: twin)   // forces the in-place branch

        try TextFileIO.writeData(Data("hi\n".utf8), to: file)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hi\n")
    }

    /// D3's half of the write path: two writers aimed at one file never
    /// interleave, so the file always holds one writer's bytes whole and the
    /// write that started last is the one that lands last.
    func testConcurrentWritesToOnePathDoNotInterleave() throws {
        let file = base.appendingPathComponent("race.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let a = Data(String(repeating: "a", count: 200_000).utf8)
        let b = Data(String(repeating: "b", count: 200_000).utf8)
        let group = DispatchGroup()
        for payload in [a, b, a, b, a, b] {
            DispatchQueue.global().async(group: group) {
                try? TextFileIO.writeData(payload, to: file)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let written = try Data(contentsOf: file)
        XCTAssertTrue(written == a || written == b, "a write landed half-way through another")
    }
}

// MARK: - DP3 / DP5 — the draft paths

@MainActor
final class DraftWriteCostTests: XCTestCase {

    private var draftsDirectory: URL {
        AppStorageLocation.applicationSupport.appendingPathComponent("Drafts", isDirectory: true)
    }

    private func draftFileNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: draftsDirectory.path))?.sorted() ?? []
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// DP5: each draft write enumerated the whole Drafts directory and
    /// prefix-matched every entry — per document, 1.5 s after every pause in
    /// typing. Behaviour must be identical: exactly one revision's pair of
    /// files survives per draft.
    func testOnlyTheLatestRevisionOfADraftSurvivesSuccessiveWrites() throws {
        let preferences = AppPreferences.current
        let previousBackup = preferences?.backupDocumentsWhileEditing
        let previousAsk = preferences?.askBeforeClosingUnsavedDocuments
        preferences?.backupDocumentsWhileEditing = true
        // Or the cleanup `close` below runs a modal alert and hangs the suite.
        preferences?.askBeforeClosingUnsavedDocuments = false
        defer {
            if let previousBackup { preferences?.backupDocumentsWhileEditing = previousBackup }
            if let previousAsk { preferences?.askBeforeClosingUnsavedDocuments = previousAsk }
        }

        let store = DocumentStore()
        let doc = store.newUntitled()
        for round in 0..<3 {
            doc.text = "round \(round)\n"
            doc.isDirty = true
            store.scheduleDraftSave(for: doc.id)
            spin(1.9)
        }

        let names = draftFileNames().filter { $0.hasPrefix(doc.draftID.uuidString) }
        XCTAssertEqual(names.count, 2, "stale draft revisions left behind: \(names)")
        XCTAssertEqual(Set(names.map { ($0 as NSString).pathExtension }), ["json", "txt"])
        let textFile = try XCTUnwrap(names.first { $0.hasSuffix(".txt") })
        XCTAssertEqual(
            try String(contentsOf: draftsDirectory.appendingPathComponent(textFile), encoding: .utf8),
            "round 2\n"
        )

        _ = store.close(doc.id)
    }

    /// DP3: ⌘Q rewrote every dirty draft inline on the main actor, even the
    /// ones whose draft on disk already held exactly that text.
    func testQuitDoesNotRewriteADraftThatIsAlreadyCurrent() throws {
        let preferences = AppPreferences.current
        let previousBackup = preferences?.backupDocumentsWhileEditing
        let previousAsk = preferences?.askBeforeClosingUnsavedDocuments
        preferences?.backupDocumentsWhileEditing = true
        preferences?.askBeforeClosingUnsavedDocuments = false
        defer {
            if let previousBackup { preferences?.backupDocumentsWhileEditing = previousBackup }
            if let previousAsk { preferences?.askBeforeClosingUnsavedDocuments = previousAsk }
        }

        let store = DocumentStore()
        store.autoSaveIsEnabled = { false }
        let doc = store.newUntitled()
        doc.text = "settled\n"
        doc.isDirty = true
        store.scheduleDraftSave(for: doc.id)
        spin(1.9)

        let before = draftFileNames().filter { $0.hasPrefix(doc.draftID.uuidString) }
        XCTAssertEqual(before.count, 2)

        XCTAssertEqual(store.applicationShouldTerminate(), .terminateNow)
        // Same files, same names: nothing was rewritten under a new revision id.
        XCTAssertEqual(draftFileNames().filter { $0.hasPrefix(doc.draftID.uuidString) }, before)

        // But an edit after that draft write must still be flushed.
        doc.text = "typed after\n"
        doc.isDirty = true
        XCTAssertEqual(store.applicationShouldTerminate(), .terminateNow)
        let after = draftFileNames().filter { $0.hasPrefix(doc.draftID.uuidString) }
        XCTAssertEqual(after.count, 2)
        XCTAssertNotEqual(after, before, "the edit made after the last draft write was not saved")
        let textFile = try XCTUnwrap(after.first { $0.hasSuffix(".txt") })
        XCTAssertEqual(
            try String(contentsOf: draftsDirectory.appendingPathComponent(textFile), encoding: .utf8),
            "typed after\n"
        )

        _ = store.close(doc.id)
    }
}

// MARK: - D13 — the sandbox's bookmarks do not come across

final class SandboxBookmarkPruneTests: XCTestCase {

    /// D13: every key came across, including ~380 KB of app-scoped
    /// security-scoped bookmark blobs that an unsandboxed process cannot use
    /// and that nothing would ever read, write or prune again.
    func testTheMigrationDropsTheDeadBookmarkDictionaries() throws {
        let fm = FileManager.default
        let container = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-container-\(UUID().uuidString)", isDirectory: true)
        let preferences = container.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: container) }

        let bundleID = "Bestchaan.SheepText.migrationtest"
        let plist: [String: Any] = [
            "sheeptext.recentFiles": ["/tmp/a.txt"],
            "sheeptext.securityScoped.fileBookmarks": ["/tmp/a.txt": Data(count: 4096)],
            "sheeptext.securityScoped.workspaceBookmarks": ["/tmp": Data(count: 4096)]
        ]
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: preferences.appendingPathComponent("\(bundleID).plist"))

        let suiteName = "Bestchaan.SheepText.migrationtest.\(UUID().uuidString)"
        guard let destination = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not make a defaults suite")
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        // Also present from an earlier migration, before this skipped them.
        destination.set(["/tmp/stale": Data(count: 16)], forKey: "sheeptext.securityScoped.fileBookmarks")

        XCTAssertTrue(AppStorageLocation.migrateFromSandboxContainer(
            container: container,
            bundleID: bundleID,
            into: destination,
            applicationSupport: nil
        ))

        XCTAssertEqual(destination.array(forKey: "sheeptext.recentFiles") as? [String], ["/tmp/a.txt"])
        for key in AppStorageLocation.obsoleteSandboxKeys {
            XCTAssertNil(destination.object(forKey: key), key)
        }
        XCTAssertTrue(destination.bool(forKey: AppStorageLocation.sandboxMigrationMarkerKey))
    }
}

// MARK: - D8 / D9 — a save failure that says what is wrong, and says it once

final class EncodingErrorMessageTests: XCTestCase {

    /// D8: `EncodingError` carried the encoding and never used it — the alert
    /// read "The operation couldn't be completed. (SheepText.EncodingError
    /// error 2.)", naming neither the encoding nor the character.
    func testCannotEncodeNamesTheEncodingTheCharacterAndTheLine() throws {
        do {
            _ = try TextFileIO.encode(
                // Thai, not an em dash — Windows-1252 does have one, at 0x97.
                text: "line one\nline two\nnearly \u{0E01} there\n",
                as: .windows1252,
                writeBOM: false
            )
            XCTFail("windows-1252 cannot store Thai")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(TextEncoding.windows1252.displayName), message)
            XCTAssertTrue(message.contains("\u{0E01}"), message)
            XCTAssertTrue(message.contains("line 3"), message)
            XCTAssertTrue(message.contains("UTF-8"), message)
        }
    }

    /// The line count has to be over the newline scalar: a CRLF pair is one
    /// Swift Character and does not compare equal to "\n".
    func testTheLineNumberIsCorrectOnCRLF() {
        let offender = TextFileIO.firstUnrepresentableCharacter(
            in: "a\r\nb\r\n\u{0E01}\r\n",                              // Thai ก on line 3
            as: .windows1252
        )
        XCTAssertEqual(offender?.character, "\u{0E01}")
        XCTAssertEqual(offender?.line, 3)
    }

    func testTextTheEncodingCanStoreHasNoOffender() {
        XCTAssertNil(TextFileIO.firstUnrepresentableCharacter(in: "plain ascii\n", as: .windows1252))
    }
}

@MainActor
final class AutoSaveFailureIsSurfacedTests: XCTestCase {

    /// D9: auto save failed into the unified log and nowhere else, for every
    /// keystroke, forever — the user who turned auto save on to stop thinking
    /// about saving had no signal at all.
    func testAutoSaveReportsAnUnencodableDocumentOnceAndStopsRetrying() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-enc-\(UUID().uuidString).txt")
        try "".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.autoSaveIsEnabled = { true }
        store.setEncoding(doc.id, encoding: .windows1252)
        doc.text = "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}\n"   // Thai
        doc.isDirty = true

        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        guard let message = doc.autoSaveFailureMessage else {
            return XCTFail("auto save failed silently")
        }
        XCTAssertTrue(message.contains(TextEncoding.windows1252.displayName), message)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")

        // Nothing has changed, so it must not re-run the encode.
        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(store.hasOutstandingAutoSave(for: doc.id))

        // Choosing an encoding that CAN store it clears the warning and saves.
        store.setEncoding(doc.id, encoding: .utf8)
        XCTAssertNil(doc.autoSaveFailureMessage)
        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        let deadline = Date().addingTimeInterval(2)
        while doc.isDirty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "\u{0E2A}\u{0E27}\u{0E31}\u{0E2A}\u{0E14}\u{0E35}\n"
        )
    }
}

// MARK: - U5 / D11 / D12 — deleted files, the BOM toggle, Save As onto an open tab

@MainActor
final class DocumentStoreSmallerFixTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-small-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ name: String, _ contents: String = "body\n") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// U5: the sidebar's Delete trashed the file and told the store nothing, so
    /// the tab stayed pointing at the trashed path and ⌘S recreated it.
    func testADirtyDocumentWhoseFileWasDeletedLosesItsURLButKeepsItsName() throws {
        let url = try makeFile("gone.txt")
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: true, showError: false) else {
            return XCTFail("could not open")
        }
        doc.text = "edited\n"
        doc.isDirty = true

        try FileManager.default.removeItem(at: url)
        store.documentWasDeleted(at: url)

        XCTAssertNil(doc.url, "⌘S would silently recreate the file the user trashed")
        XCTAssertEqual(doc.displayName, "gone.txt", "the tab lost the name of the file it holds")
        XCTAssertTrue(doc.isDirty)
        XCTAssertTrue(store.documents.contains { $0.id == doc.id })
        XCTAssertFalse(store.recentFiles.contains { $0.canonicalFileURL == url.canonicalFileURL })
        // `url == nil` is what routes the next ⌘S into `promptSaveAs`, so the
        // file is not recreated behind the user's back. Not driven here: that
        // path runs `NSSavePanel.runModal()`, which would hang the suite.
    }

    /// A clean tab has nothing to lose, so it just closes.
    func testACleanDocumentWhoseFileWasDeletedIsClosed() throws {
        let url = try makeFile("clean.txt")
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        try FileManager.default.removeItem(at: url)
        store.documentWasDeleted(at: url)

        XCTAssertFalse(store.documents.contains { $0.id == doc.id })
    }

    /// Deleting a FOLDER takes every document under it — matched by path
    /// components, so a sibling whose name merely starts with the same letters
    /// is left alone.
    func testDeletingAFolderReachesTheDocumentsInsideItAndNoOthers() throws {
        let inside = directory.appendingPathComponent("proj", isDirectory: true)
        let sibling = directory.appendingPathComponent("proj-secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let a = inside.appendingPathComponent("a.txt")
        let b = sibling.appendingPathComponent("b.txt")
        try "a\n".write(to: a, atomically: true, encoding: .utf8)
        try "b\n".write(to: b, atomically: true, encoding: .utf8)

        let store = DocumentStore()
        guard let docA = store.open(url: a, rememberRecent: false, showError: false),
              let docB = store.open(url: b, rememberRecent: false, showError: false)
        else { return XCTFail("could not open") }
        docA.isDirty = true
        docB.isDirty = true

        try FileManager.default.removeItem(at: inside)
        store.documentWasDeleted(at: inside)

        XCTAssertNil(docA.url)
        XCTAssertEqual(docB.url?.canonicalFileURL, b.canonicalFileURL, "a sibling folder was caught by a string prefix")
    }

    /// D11: `.utf16` / `.utf32` are the endian-agnostic entries and Foundation
    /// writes their BOM unconditionally, so `writeBOM` was a no-op in both
    /// directions — the status bar said "no BOM" over a file starting FF FE.
    func testTurningTheBOMOffOnAUTF16DocumentActuallyRemovesIt() throws {
        let url = directory.appendingPathComponent("wide.txt")
        try Data().write(to: url)
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.setEncoding(doc.id, encoding: .utf16)
        XCTAssertTrue(doc.hasBOM)

        store.setBOM(doc.id, hasBOM: false)
        doc.text = "hi"
        doc.isDirty = true
        store.save(doc.id)

        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x68, 0x00, 0x69, 0x00],
                       "the BOM was written anyway")
    }

    /// And turning it back on still writes one.
    func testTurningTheBOMBackOnWritesIt() throws {
        let url = directory.appendingPathComponent("wide2.txt")
        try Data().write(to: url)
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.setEncoding(doc.id, encoding: .utf16)
        store.setBOM(doc.id, hasBOM: false)
        store.setBOM(doc.id, hasBOM: true)
        doc.text = "hi"
        doc.isDirty = true
        store.save(doc.id)

        XCTAssertEqual(Array([UInt8](try Data(contentsOf: url)).prefix(2)), [0xFF, 0xFE])
    }

    /// D12: `open(url:)` dedupes by canonical URL; Save As did not, so it could
    /// leave two tabs onto one file, each overwriting the other on ⌘S.
    func testSaveAsOntoAFileAnotherTabHoldsIsRefused() throws {
        let url = try makeFile("target.txt", "original\n")
        let store = DocumentStore()
        guard let first = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        let second = store.newUntitled()
        second.text = "would clobber\n"
        second.isDirty = true

        var reported = 0
        store.reportSaveAsConflict = { _, _ in reported += 1 }
        XCTAssertFalse(store.saveAs(second, to: url))

        XCTAssertEqual(reported, 1)
        XCTAssertNil(second.url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
        XCTAssertEqual(store.documents.filter { $0.url?.canonicalFileURL == url.canonicalFileURL }.count, 1)
        XCTAssertEqual(first.url?.canonicalFileURL, url.canonicalFileURL)
    }

    /// Saving a document over its OWN file is Save As's normal case.
    func testSaveAsOntoTheDocumentsOwnFileStillWorks() throws {
        let url = try makeFile("self.txt")
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        doc.text = "rewritten\n"
        doc.isDirty = true
        XCTAssertTrue(store.saveAs(doc, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "rewritten\n")
    }
}

// MARK: - D6 — an unmounted volume must not erase what is remembered

@MainActor
final class UnreachablePathsArePreservedTests: XCTestCase {

    /// A path under a directory that does not exist — the same answer
    /// `fileExists` gives for a volume that has not mounted yet.
    private let unmounted = "/Volumes/NotMountedRightNow/work/notes.txt"

    private var file: URL!

    override func setUpWithError() throws {
        file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-unmounted-\(UUID().uuidString).txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
        let defaults = AppStorageLocation.defaults
        for key in ["sheeptext.recentFiles", "sheeptext.session.openFiles",
                    "sheeptext.session.activeFile", "sheeptext.recentWorkspaces"] {
            defaults.removeObject(forKey: key)
        }
    }

    /// The prune was in memory, but the next `addRecent` wrote the pruned list
    /// back — so one launch before the OneDrive mount came up, plus opening any
    /// file, emptied Open Recent for good.
    func testRecentsOnAnUnreachableVolumeSurviveOpeningAnotherFile() throws {
        let defaults = AppStorageLocation.defaults
        defaults.set([unmounted], forKey: "sheeptext.recentFiles")

        let store = DocumentStore()
        _ = store.open(url: file, showError: false)

        let stored = defaults.array(forKey: "sheeptext.recentFiles") as? [String] ?? []
        XCTAssertTrue(stored.contains(unmounted), "an unreachable recent was erased")
        XCTAssertTrue(stored.contains(file.path))
    }

    /// Same for the restored session: a tab that could not be reached is not a
    /// tab the user closed.
    func testSessionTabsOnAnUnreachableVolumeAreKept() throws {
        let defaults = AppStorageLocation.defaults
        defaults.set([unmounted, file.path], forKey: "sheeptext.session.openFiles")

        let store = DocumentStore()
        store.restoreSessionTabs()

        let stored = defaults.stringArray(forKey: "sheeptext.session.openFiles") ?? []
        XCTAssertTrue(stored.contains(unmounted), "an unreachable session tab was erased")
        XCTAssertTrue(stored.contains(file.path))
        // Count the tab the session opened, not every tab: `restoreSessionTabs`
        // also runs `restoreDrafts`, and the test process's Drafts directory is
        // shared with every other class that ran before this one in it — a
        // draft one of them left behind came back as a second tab and failed
        // the old `documents.count == 1` in the full parallel run only.
        let restored = store.documents.filter { $0.url?.path == file.path }
        XCTAssertEqual(restored.count, 1)

        // Closing the one tab that did open must still not take the other with it.
        let opened = try XCTUnwrap(restored.first)
        XCTAssertTrue(store.close(opened.id))
        let afterClose = defaults.stringArray(forKey: "sheeptext.session.openFiles") ?? []
        XCTAssertTrue(afterClose.contains(unmounted), "closing another tab erased the unreachable one")
        XCTAssertFalse(afterClose.contains(file.path))
    }

    /// A file that really is gone — the read fails with "no such file" — is the
    /// one signal that means forget it.
    func testAFileThatIsReallyGoneIsDropped() throws {
        let defaults = AppStorageLocation.defaults
        let missing = file.deletingLastPathComponent()
            .appendingPathComponent("sheeptext-really-gone-\(UUID().uuidString).txt")
        defaults.set([missing.path], forKey: "sheeptext.session.openFiles")
        defaults.set([missing.path], forKey: "sheeptext.recentFiles")

        let store = DocumentStore()
        store.restoreSessionTabs()
        XCTAssertNil(store.open(url: missing, showError: false))

        XCTAssertFalse((defaults.array(forKey: "sheeptext.recentFiles") as? [String] ?? []).contains(missing.path))
        XCTAssertFalse((defaults.stringArray(forKey: "sheeptext.session.openFiles") ?? []).contains(missing.path))
    }

    func testRecentWorkspacesOnAnUnreachableVolumeAreKept() throws {
        let defaults = AppStorageLocation.defaults
        let unmountedFolder = "/Volumes/NotMountedRightNow/work"
        defaults.set([unmountedFolder], forKey: "sheeptext.recentWorkspaces")

        let store = WorkspaceStore()
        XCTAssertEqual(store.recentWorkspaces.map(\.path), [unmountedFolder])

        store.open(file.deletingLastPathComponent())
        let stored = defaults.stringArray(forKey: "sheeptext.recentWorkspaces") ?? []
        XCTAssertTrue(stored.contains(unmountedFolder), "an unreachable workspace was erased")
    }
}

// MARK: - D5 / DP1 — Replace in Files partial failure, and cloud-only files

final class ReplaceInFilesRecoveryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        // Resolved, because /var is a symlink to /private/var and FileNode's
        // scan hands back the resolved spelling — `relativePath` and the backup
        // layout are both computed by string prefix against the root.
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("sheeptext-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func options(_ query: String) -> FindInFilesOptions {
        FindInFilesOptions(query: query, caseSensitive: true, wholeWord: false, useRegex: false)
    }

    /// D5: any throw out of the loop abandoned the pass with the files before it
    /// already rewritten, lost the backup directory, and skipped the tab reload.
    /// The trigger is ordinary: one file in the tree is not valid UTF-8, so it
    /// decodes as Windows-1252, and the replacement contains a character
    /// Windows-1252 cannot store.
    func testAFileThatCannotBeEncodedDoesNotAbandonTheWholePass() throws {
        // `a.txt` sorts first, so it is rewritten before `b.txt` fails.
        try "token here\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        var windows1252 = Data("token ".utf8)
        windows1252.append(0x92)                       // a curly quote: not UTF-8
        windows1252.append(contentsOf: Array("\n".utf8))
        try windows1252.write(to: root.appendingPathComponent("b.txt"))
        try "token here\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)

        let summary = try FindInFilesEngine.replaceAll(
            root: root,
            tree: FileNode.scan(at: root),
            options: options("token"),
            replacement: "โทเคน"                        // Windows-1252 cannot store Thai
        )

        XCTAssertEqual(summary.failures.map { $0.url.lastPathComponent }, ["b.txt"])
        XCTAssertEqual(summary.changedURLs.count, 2, "the files after the failure were skipped")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("c.txt"), encoding: .utf8),
            "โทเคน here\n"
        )
        guard let backupDirectory = summary.backupDirectory else {
            return XCTFail("the backup directory was lost with the throw")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirectory.path))
        // Located by name rather than by relative path: the backup mirrors
        // `url.path(relativeTo: root)`, and /var/folders is spelled two ways on
        // macOS (`resolvingSymlinksInPath` deliberately does not add /private,
        // while `contentsOfDirectory` does), so the depth depends on which
        // spelling the workspace root carries.
        let backedUp = FileManager.default
            .enumerator(at: backupDirectory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "a.txt" }
        guard let backedUp else { return XCTFail("a.txt was not backed up") }
        XCTAssertEqual(try String(contentsOf: backedUp, encoding: .utf8), "token here\n")
        try? FileManager.default.removeItem(at: backupDirectory)
    }

    /// DP1: a File Provider placeholder reports its LOGICAL size, so it sails
    /// through the 2 MB gate and `Data(contentsOf:)` downloads it. One search
    /// over a synced folder pulled the whole tree onto the disk.
    func testSearchSkipsCloudOnlyFilesWithoutReadingThem() throws {
        try "needle one\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try "needle two\n".write(to: root.appendingPathComponent("cloud.txt"), atomically: true, encoding: .utf8)
        let placeholder = root.appendingPathComponent("cloud.txt")

        var read: Set<String> = []
        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: options("needle"),
            isDataless: { url in
                read.insert(url.lastPathComponent)
                return url.lastPathComponent == placeholder.lastPathComponent
            }
        )

        XCTAssertEqual(summary.matches.map { $0.url.lastPathComponent }, ["local.txt"])
        XCTAssertEqual(summary.datalessFiles, 1)
        XCTAssertEqual(summary.skippedFiles, 1)
        XCTAssertEqual(summary.searchedFiles, 1)
        XCTAssertEqual(read, ["local.txt", "cloud.txt"], "the probe ran for every candidate")
    }

    func testReplaceSkipsCloudOnlyFiles() throws {
        try "needle\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try "needle\n".write(to: root.appendingPathComponent("cloud.txt"), atomically: true, encoding: .utf8)

        let summary = try FindInFilesEngine.replaceAll(
            root: root,
            tree: FileNode.scan(at: root),
            options: options("needle"),
            replacement: "pin",
            isDataless: { $0.lastPathComponent == "cloud.txt" }
        )

        XCTAssertEqual(summary.datalessFiles, 1)
        XCTAssertEqual(summary.changedURLs.map(\.lastPathComponent), ["local.txt"])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("cloud.txt"), encoding: .utf8),
            "needle\n"
        )
        if let backupDirectory = summary.backupDirectory {
            try? FileManager.default.removeItem(at: backupDirectory)
        }
    }

    /// The real probe: an ordinary local file is never mistaken for a
    /// placeholder. (A decmpfs-compressed file also has `st_blocks == 0`, which
    /// is why the flag is what is tested and not the block count.)
    func testAnOrdinaryFileIsNotReportedAsCloudOnly() throws {
        let url = root.appendingPathComponent("plain.txt")
        try "hello\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(FindInFilesEngine.isDataless(url))
        XCTAssertFalse(FindInFilesEngine.isDataless(root.appendingPathComponent("missing.txt")))
    }
}

// MARK: - D3 — a write handed to a background task can still be called off

/// A `var` captured by two threads is not expressible under strict concurrency;
/// this is the smallest thing that is.
private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class PendingDocumentWriteTests: XCTestCase {

    /// The whole point: `Task.detached` is not a child task, so the auto-save
    /// task's cancellation never reached its write.
    func testACancelledWriteNeverRuns() {
        let write = PendingDocumentWrite()
        write.cancel()
        var ran = false
        XCTAssertFalse(write.run { ran = true })
        XCTAssertFalse(ran)
    }

    func testAnUncancelledWriteRuns() {
        let write = PendingDocumentWrite()
        var ran = false
        XCTAssertTrue(write.run { ran = true })
        XCTAssertTrue(ran)
    }

    /// `cancel()` has to WAIT for a write that has already begun, so the caller
    /// that is about to write the same path is the last writer either way.
    func testCancelWaitsForAWriteThatHasAlreadyBegun() {
        let write = PendingDocumentWrite()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let writeFinished = ThreadSafeFlag()

        DispatchQueue.global().async {
            write.run {
                started.signal()
                finished.wait()
                writeFinished.set()
            }
        }
        started.wait()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { finished.signal() }
        write.cancel()

        XCTAssertTrue(writeFinished.value, "cancel() returned while the write was still running")
    }
}

// MARK: - D2 / D3 / D4 / U3 — save ordering

@MainActor
final class SaveOrderingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFile(_ contents: String = "start\n") throws -> URL {
        let url = directory.appendingPathComponent("doc.txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// D2: cancelling the auto-save task does not un-write the bytes, so the
    /// document has to adopt the file's new state anyway. It used to return one
    /// line above the `captureDiskState` that exists for exactly this reason,
    /// and the 4 s poll then reported the app's own write as an external change
    /// and offered "Reload from Disk" — which discards the edits and the draft.
    func testACancelledAutoSaveStillAdoptsTheFileItWrote() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.autoSaveIsEnabled = { true }
        doc.text = "written by auto save\n"
        doc.isDirty = true

        // Land a cancellation in the window between the write returning and the
        // continuation deciding what to do with it — the keystroke case.
        store.autoSaveWriteDidFinish = { [weak store] in
            store?.scheduleAutoSave(for: doc.id, isEnabled: false, delay: 0)
        }
        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        spin(0.6)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "written by auto save\n")
        XCTAssertEqual(doc.diskModificationDate, modificationDate(of: url),
                       "the poll will read the app's own write as an external change")
    }

    /// D3: a manual save must not leave a superseded auto save scheduled behind
    /// it — that task wakes later and writes the bytes the user replaced.
    func testAManualSaveLeavesNoAutoSaveOutstanding() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.autoSaveIsEnabled = { true }

        doc.text = "auto\n"
        doc.isDirty = true
        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 30)
        XCTAssertTrue(store.hasOutstandingAutoSave(for: doc.id))

        doc.text = "manual\n"
        doc.isDirty = true
        store.save(doc.id)

        XCTAssertFalse(store.hasOutstandingAutoSave(for: doc.id),
                       "a superseded auto save is still scheduled after ⌘S")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "manual\n")
    }

    /// The same for the close path: "Don't Save" must not leave a write running
    /// that lands after the user declined the edits.
    func testClosingLeavesNoAutoSaveOutstanding() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        let preferences = AppPreferences.current
        let previous = preferences?.askBeforeClosingUnsavedDocuments
        preferences?.askBeforeClosingUnsavedDocuments = false
        defer { if let previous { preferences?.askBeforeClosingUnsavedDocuments = previous } }

        store.autoSaveIsEnabled = { true }
        doc.text = "declined\n"
        doc.isDirty = true
        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 30)

        XCTAssertTrue(store.close(doc.id))
        XCTAssertFalse(store.hasOutstandingAutoSave(for: doc.id))
        spin(0.2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "start\n")
    }

    /// `URL` caches resource values on the value, and every copy of a URL shares
    /// that cache — so the URL a document was opened through answers every later
    /// stat with the open-time numbers. That is the URL the four-second poll
    /// stats through, so no external change it looked at could ever be seen.
    func testTheDiskPollSeesAChangeThroughTheURLTheDocumentWasOpenedWith() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        // Foundation's own answer through that URL value is the stale one:
        XCTAssertEqual(doc.diskFileSize, 6)
        try "much longer than before\n".write(to: url, atomically: true, encoding: .utf8)

        store.checkForExternalChanges()
        spin(0.5)

        XCTAssertEqual(doc.text, "much longer than before\n",
                       "the poll never noticed the file change")
        XCTAssertEqual(doc.diskFileSize, 24)
    }

    /// D4: a manual save never re-stat-ed the file, so anything that rewrote it
    /// inside the 4-second poll window was overwritten with no prompt at all.
    func testAManualSaveAsksBeforeOverwritingAnExternalChange() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }

        // Somebody else rewrote it — a git checkout, a formatter, a sync client.
        try "from the other tool\n".write(to: url, atomically: true, encoding: .utf8)
        doc.text = "mine\n"
        doc.isDirty = true

        var asked = 0
        store.resolveExternalChangeAtSave = { _ in asked += 1; return .cancel }
        store.save(doc.id)

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "from the other tool\n",
                       "⌘S overwrote an external change without asking")
        XCTAssertTrue(doc.isDirty)

        store.resolveExternalChangeAtSave = { _ in asked += 1; return .overwrite }
        store.save(doc.id)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n")
        XCTAssertFalse(doc.isDirty)
    }

    /// An unchanged file must not ask — this runs on every ⌘S.
    func testAnUnchangedFileIsSavedWithoutAsking() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.resolveExternalChangeAtSave = { _ in
            XCTFail("asked about a file nobody touched")
            return .cancel
        }
        doc.text = "mine\n"
        doc.isDirty = true
        store.save(doc.id)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine\n")
    }

    /// D4, auto-save half: it must not overwrite the external change either —
    /// it has nobody to ask, so it stays out of the poll's way.
    func testAutoSaveDoesNotOverwriteAnExternalChange() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        store.autoSaveIsEnabled = { true }
        try "from the other tool\n".write(to: url, atomically: true, encoding: .utf8)
        doc.text = "mine\n"
        doc.isDirty = true

        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        spin(0.5)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "from the other tool\n")
        XCTAssertTrue(doc.isDirty)
    }

    /// U3: a scheduled auto save is a Task asleep, and ⌘Q neither wakes it nor
    /// waits for a write in flight. With the close prompt off — the setting a
    /// user who relies on auto save turns off — the edits were simply gone.
    func testQuittingRunsThePendingAutoSave() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        let preferences = AppPreferences.current
        let previousAsk = preferences?.askBeforeClosingUnsavedDocuments
        let previousBackup = preferences?.backupDocumentsWhileEditing
        preferences?.askBeforeClosingUnsavedDocuments = false
        preferences?.backupDocumentsWhileEditing = false
        defer {
            if let previousAsk { preferences?.askBeforeClosingUnsavedDocuments = previousAsk }
            if let previousBackup { preferences?.backupDocumentsWhileEditing = previousBackup }
        }

        store.autoSaveIsEnabled = { true }
        doc.text = "typed just before quitting\n"
        doc.isDirty = true
        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 30)

        XCTAssertEqual(store.applicationShouldTerminate(), .terminateNow)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "typed just before quitting\n")
        XCTAssertFalse(doc.isDirty)
    }

    /// With auto save OFF, quitting must not start saving files by itself —
    /// that is what the close prompt and the draft are for.
    func testQuittingDoesNotSaveWhenAutoSaveIsOff() throws {
        let url = try makeFile()
        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        let preferences = AppPreferences.current
        let previousAsk = preferences?.askBeforeClosingUnsavedDocuments
        preferences?.askBeforeClosingUnsavedDocuments = false
        defer { if let previousAsk { preferences?.askBeforeClosingUnsavedDocuments = previousAsk } }

        store.autoSaveIsEnabled = { false }
        doc.text = "not saved\n"
        doc.isDirty = true

        XCTAssertEqual(store.applicationShouldTerminate(), .terminateNow)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "start\n")
        XCTAssertTrue(doc.isDirty)
    }
}
