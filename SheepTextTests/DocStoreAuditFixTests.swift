//
//  DocStoreAuditFixTests.swift
//  Regressions for the document / file / IO audit (September 2026).
//
//  One test (or one small group) per finding ID. Each was written against the
//  unfixed code and watched to fail first.
//

import AppKit
import XCTest
@testable import SheepText

// MARK: - D1 Find in Files match cap

@MainActor
final class FindInFilesCapTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-findcap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeFiles(count: Int, matchesPerFile: Int) throws {
        for fileIndex in 0..<count {
            var lines: [String] = []
            for lineIndex in 0..<matchesPerFile {
                lines.append("let padding\(lineIndex) = 0")
                lines.append("needle marker \(fileIndex)-\(lineIndex)")
            }
            try lines.joined(separator: "\n").write(
                to: root.appendingPathComponent(String(format: "file-%03d.swift", fileIndex)),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// D1: the caller passed `maxMatches - matches.count` as a budget and the
    /// scanner compared the running *total* against it, so it stopped at
    /// `count >= limit - count` — an effective cap of 500 out of 1000, with
    /// `hitLimit` reported false because the outer guard never tripped.
    func testMatchCapIsTheFullThousandAndReportsHittingIt() throws {
        try writeFiles(count: 30, matchesPerFile: 40)   // 1200 available
        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: FindInFilesOptions(query: "needle", caseSensitive: true, wholeWord: false, useRegex: false)
        )
        XCTAssertEqual(summary.matches.count, 1000)
        XCTAssertTrue(summary.hitLimit)
    }

    /// A result under the cap must not claim to be limited.
    func testUnderTheCapDoesNotReportHittingIt() throws {
        try writeFiles(count: 5, matchesPerFile: 10)    // 50 available
        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: FindInFilesOptions(query: "needle", caseSensitive: true, wholeWord: false, useRegex: false)
        )
        XCTAssertEqual(summary.matches.count, 50)
        XCTAssertFalse(summary.hitLimit)
    }

    /// D14: the engine is polled for cancellation, so a superseded search stops
    /// instead of running to completion behind the one the user is waiting for.
    func testCancellationStopsTheSearch() throws {
        try writeFiles(count: 30, matchesPerFile: 40)
        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: FindInFilesOptions(query: "needle", caseSensitive: true, wholeWord: false, useRegex: false),
            isCancelled: { true }
        )
        XCTAssertTrue(summary.matches.isEmpty)
        XCTAssertFalse(summary.hitLimit)
    }

    /// D15: whole word wrapped the pattern as `\bfoo|bar\b`, and alternation
    /// binds looser than concatenation — that is "\bfoo" OR "bar\b".
    func testWholeWordWithAlternationGroupsThePattern() throws {
        try "alpha beta\nxxbetaxx\nxxalphaxx\n".write(
            to: root.appendingPathComponent("words.txt"),
            atomically: true,
            encoding: .utf8
        )
        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: FindInFilesOptions(query: "alpha|beta", caseSensitive: true, wholeWord: true, useRegex: true)
        )
        // Only line 1 has either word standing alone; both hits are on it.
        XCTAssertEqual(summary.matches.count, 2)
        XCTAssertEqual(Set(summary.matches.map(\.lineNumber)), [1])
    }

    /// D23 rewrote the scanner to run one regex over the whole file and look the
    /// line number up in a table. Line numbers, columns and previews must be
    /// exactly what the old per-line scan produced — CRLF included.
    func testLineNumbersColumnsAndPreviewsSurviveTheSinglePassRewrite() throws {
        let body = "one needle here\r\nplain\r\n  needle twice needle\r\nlast\r\n"
        try body.write(to: root.appendingPathComponent("crlf.txt"), atomically: true, encoding: .utf8)

        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: FindInFilesOptions(query: "needle", caseSensitive: true, wholeWord: false, useRegex: false)
        )
        XCTAssertEqual(summary.matches.map(\.lineNumber), [1, 3, 3])
        XCTAssertEqual(summary.matches.map(\.column), [5, 3, 16])
        XCTAssertEqual(summary.matches[0].preview, "one needle here")
        XCTAssertEqual(summary.matches[1].preview, "needle twice needle")
    }

    /// ^ and $ used to mean "start/end of line" for free, because the regex was
    /// fed one line at a time. The single pass has to keep that.
    func testLineAnchorsStillMatchPerLine() throws {
        try "alpha\nbeta\nalpha\n".write(
            to: root.appendingPathComponent("anchors.txt"),
            atomically: true,
            encoding: .utf8
        )
        let summary = try FindInFilesEngine.search(
            root: root,
            tree: FileNode.scan(at: root),
            options: FindInFilesOptions(query: "^alpha$", caseSensitive: true, wholeWord: false, useRegex: true)
        )
        XCTAssertEqual(summary.matches.map(\.lineNumber), [1, 3])
    }
}

// MARK: - D2 / D5 / D7 encoding detection and round-trip

@MainActor
final class EncodingRoundTripTests: XCTestCase {

    private let sample = "let value = 1\nนี่คือภาษาไทย\nlast line\n"

    private func roundTrip(_ data: Data, label: String, expectEncoding: TextEncoding) {
        let decoded = TextFileIO.decode(data: data)
        XCTAssertEqual(decoded.text, sample, "\(label): wrong text")
        XCTAssertEqual(decoded.encoding, expectEncoding, "\(label): wrong encoding")
        XCTAssertFalse(decoded.looksBinary, "\(label): wide text is not binary")

        let reencoded = try? TextFileIO.encode(
            text: decoded.text,
            as: decoded.encoding,
            writeBOM: decoded.hadBOM
        )
        XCTAssertEqual(reencoded, data, "\(label): save did not reproduce the file")
    }

    /// D2, the whole matrix. A BOM-less UTF-16LE file (a routine Windows export)
    /// used to decode through `.utf16`, which without a BOM means BIG-endian —
    /// so it came out as CJK garbage that `isPlausibleText` accepted, at half the
    /// real length, and saving re-encoded through `.utf16`, which writes
    /// little-endian *with* a BOM. The file was destroyed.
    func testWideUnicodeRoundTripsWithAndWithoutBOM() {
        roundTrip(Data([0xFF, 0xFE]) + sample.data(using: .utf16LittleEndian)!,
                  label: "UTF-16LE + BOM", expectEncoding: .utf16LE)
        roundTrip(Data([0xFE, 0xFF]) + sample.data(using: .utf16BigEndian)!,
                  label: "UTF-16BE + BOM", expectEncoding: .utf16BE)
        roundTrip(sample.data(using: .utf16LittleEndian)!,
                  label: "UTF-16LE no BOM", expectEncoding: .utf16LE)
        roundTrip(sample.data(using: .utf16BigEndian)!,
                  label: "UTF-16BE no BOM", expectEncoding: .utf16BE)

        roundTrip(Data([0xFF, 0xFE, 0x00, 0x00]) + sample.data(using: .utf32LittleEndian)!,
                  label: "UTF-32LE + BOM", expectEncoding: .utf32LE)
        roundTrip(Data([0x00, 0x00, 0xFE, 0xFF]) + sample.data(using: .utf32BigEndian)!,
                  label: "UTF-32BE + BOM", expectEncoding: .utf32BE)
        roundTrip(sample.data(using: .utf32LittleEndian)!,
                  label: "UTF-32LE no BOM", expectEncoding: .utf32LE)
        roundTrip(sample.data(using: .utf32BigEndian)!,
                  label: "UTF-32BE no BOM", expectEncoding: .utf32BE)
    }

    func testUTF8RoundTripsWithAndWithoutBOM() {
        roundTrip(Data(sample.utf8), label: "UTF-8", expectEncoding: .utf8)
        roundTrip(Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8),
                  label: "UTF-8 + BOM", expectEncoding: .utf8WithBOM)
    }

    /// The other half of D2: a single-byte file with an even byte count must not
    /// be swallowed by a wide encoding, and whatever it is decoded as has to be
    /// able to write itself back.
    func testSingleByteFileIsNotDecodedAsWideUnicode() throws {
        let line = "Caf\u{E9} r\u{E9}sum\u{E9} na\u{EF}ve value 42\n"
        var unit: [UInt8] = []
        for scalar in line.unicodeScalars { unit.append(UInt8(scalar.value & 0xFF)) }
        var bytes: [UInt8] = []
        while bytes.count < 20_000 { bytes.append(contentsOf: unit) }
        if bytes.count % 2 == 1 { bytes.append(0x0A) }
        XCTAssertEqual(bytes.count % 2, 0, "fixture must be an even length to reproduce the bug")

        let decoded = TextFileIO.decode(data: Data(bytes))
        XCTAssertFalse(decoded.encoding.usesWideCodeUnits, "decoded as \(decoded.encoding.rawValue)")
        XCTAssertEqual((decoded.text as NSString).length, bytes.count,
                       "a single-byte file has one character per byte")
        // And it must survive a save, which ISO-2022-JP (early in the chain, and
        // happy to "decode" 8-bit bytes) could not do: its encoder refuses them.
        XCTAssertNotNil(try? TextFileIO.encode(text: decoded.text, as: decoded.encoding, writeBOM: decoded.hadBOM))
    }

    /// D2 again: the chain must not contain an entry whose endianness is
    /// unresolved, because the decode and the encode then disagree.
    func testDetectionChainHasNoEndianAmbiguousEntries() {
        XCTAssertFalse(TextEncoding.detectionChain.contains(.utf16))
        XCTAssertFalse(TextEncoding.detectionChain.contains(.utf32))
    }

    /// D7: `String(data:encoding:.utf8)` swallows a UTF-8 BOM, and the manual
    /// path recorded `encoding.writesBOMByDefault` (false for plain UTF-8)
    /// instead — so a BOM'd file opened with auto-detection off lost its BOM.
    /// D5: the same path never asked whether the bytes look binary.
    func testManualEncodingPathReportsBOMAndBinary() {
        let text = "hello\n"
        let bomd = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        let decoded = TextFileIO.decode(data: bomd, as: .utf8)
        XCTAssertEqual(decoded?.text, text)
        XCTAssertEqual(decoded?.hadBOM, true)
        XCTAssertEqual(
            try? TextFileIO.encode(text: decoded!.text, as: .utf8, writeBOM: decoded!.hadBOM),
            bomd
        )

        var binary: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        binary.append(contentsOf: Array(repeating: 0x00, count: 100))
        XCTAssertEqual(TextFileIO.decode(data: Data(binary), as: .windows1252)?.looksBinary, true)
        // …but a wide encoding is exempt: its NULs are how it spells ASCII.
        XCTAssertEqual(
            TextFileIO.decode(data: text.data(using: .utf16LittleEndian)!, as: .utf16LE)?.looksBinary,
            false
        )
    }

    /// D24 is an optimisation of the fallback chain, not a change to it: the
    /// candidate is now chosen from a 64 KB prefix and only then decoded in
    /// full. A file whose prefix and whole differ has to give the same answer.
    func testPrefixDetectionAgreesWithWholeFileDetection() {
        // 200 KB of Shift-JIS, i.e. well past the probe window.
        let japanese = String(repeating: "日本語のテキストです。\n", count: 6_000)
        let data = japanese.data(using: .shiftJIS)!
        XCTAssertGreaterThan(data.count, 128 * 1024)
        let decoded = TextFileIO.decode(data: data)
        XCTAssertEqual(decoded.text, japanese)
        XCTAssertEqual(decoded.encoding, .shiftJIS)
    }
}

// MARK: - D3 / D4 / D12 / D18 / D25 save behaviour

@MainActor
final class DocumentSaveBehaviourTests: XCTestCase {

    /// D3: `prepareSave` applied the trailing-whitespace trim by assigning
    /// `doc.text`, and auto save calls it without going through the editor — so
    /// `updateNSView` found `viewText != document.text` and replaced the text
    /// view's whole string, losing the undo stack, the folds and the caret,
    /// three seconds after the user stopped typing.
    ///
    /// The test drives the property the fix rests on: preparing a save is a pure
    /// read of the document.
    func testPreparingASaveDoesNotMutateTheDocument() throws {
        let url = try makeTemporaryFile(contents: "")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        doc.autoTrimTrailingWhitespace = true
        doc.text = "trailing spaces here   \nand here\t\n"
        let before = doc.text
        let beforeRevision = doc.revision

        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        // Give the scheduled task a chance to run its whole cycle.
        let deadline = Date().addingTimeInterval(2)
        while doc.isDirty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(doc.text, before, "auto save rewrote the document text")
        XCTAssertEqual(doc.revision, beforeRevision, "auto save bumped the text revision")
    }

    /// The trim still has to happen on a manual save, including for a document
    /// that has no editor (Save All over a background tab).
    func testManualSaveStillTrimsWithoutAnEditor() throws {
        let url = try makeTemporaryFile(contents: "")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        doc.autoTrimTrailingWhitespace = true
        doc.text = "a   \nb\t\n"
        doc.isDirty = true
        store.save(doc.id)

        XCTAssertEqual(doc.text, "a\nb\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\n")
        XCTAssertFalse(doc.isDirty)
    }

    /// D4: `Document.revision` is what tells the auto-save continuation whether
    /// the document it finds is still the one it encoded. A string comparison
    /// cannot see an edit-and-edit-back.
    func testRevisionCountsEveryAssignmentIncludingEditAndEditBack() {
        let doc = Document(url: nil, initialText: "a", encoding: .utf8, hasBOM: false)
        let start = doc.revision
        doc.text = "ab"
        doc.text = "a"
        XCTAssertEqual(doc.revision, start + 2)
        XCTAssertEqual(doc.textUTF16Count, 1)
    }

    /// D12: an external change was only noticed when the mtime moved FORWARD by
    /// more than a quarter second, so `git checkout`, `cp -p` and `rsync -t` —
    /// which restore the old mtime — went unnoticed. The size is tracked
    /// alongside it now.
    func testDocumentTracksBothDiskModificationDateAndSize() throws {
        let url = try makeTemporaryFile(contents: "hello\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        XCTAssertNotNil(doc.diskModificationDate)
        XCTAssertEqual(doc.diskFileSize, 6)
    }

    /// D25: an auto save is not the user opening a file and must not push the
    /// document to the top of Open Recent (which is a UserDefaults rewrite every
    /// few seconds while typing).
    func testAutoSaveDoesNotTouchRecentFiles() throws {
        let url = try makeTemporaryFile(contents: "x\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        let recentsBefore = store.recentFiles
        doc.text = "x changed\n"
        doc.isDirty = true

        store.scheduleAutoSave(for: doc.id, isEnabled: true, delay: 0.01)
        let deadline = Date().addingTimeInterval(2)
        while doc.isDirty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertFalse(doc.isDirty, "auto save did not complete")
        XCTAssertEqual(store.recentFiles, recentsBefore)
    }

    private func makeTemporaryFile(contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-save-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - D6 / D10 / D11 store bookkeeping

@MainActor
final class DocumentStoreBookkeepingTests: XCTestCase {

    /// D11: identity used `standardizedFileURL`, which does not resolve
    /// symlinks — and on macOS /tmp, /var and /etc all are. Opening the same
    /// file by both paths gave two tabs, each overwriting the other's save.
    func testSymlinkedPathsAreTheSameDocument() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-symlink-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDirectory)

        let real = realDirectory.appendingPathComponent("body.txt")
        try "body\n".write(to: real, atomically: true, encoding: .utf8)
        let viaLink = link.appendingPathComponent("body.txt")

        // The canonicaliser itself: standardizedFileURL does not resolve the
        // link, which is the whole bug.
        XCTAssertNotEqual(viaLink.standardizedFileURL, real.standardizedFileURL)
        XCTAssertEqual(viaLink.canonicalFileURL, real.canonicalFileURL)

        let store = DocumentStore()
        let first = store.open(url: real, rememberRecent: false, showError: false)
        let second = store.open(url: viaLink, rememberRecent: false, showError: false)
        XCTAssertNotNil(first)
        XCTAssertIdentical(first, second, "the same file opened as two tabs")
        XCTAssertEqual(store.documents.count, 1)
    }

    /// D10 / U5: there were two copy-pasted close paths and only one of them
    /// honoured `askBeforeClosingUnsavedDocuments`, so the tab-bar ✕ and
    /// "Close Other Tabs" prompted even for a user who had turned it off.
    /// With the preference off, closing a dirty document must not block.
    func testBothCloseEntryPointsHonourTheAskPreference() {
        let preferences = AppPreferences.current
        let previous = preferences?.askBeforeClosingUnsavedDocuments
        preferences?.askBeforeClosingUnsavedDocuments = false
        defer { if let previous { preferences?.askBeforeClosingUnsavedDocuments = previous } }

        let store = DocumentStore()
        let first = store.newUntitled()
        first.text = "dirty"
        first.isDirty = true
        XCTAssertTrue(store.requestCloseTabFromUI(first.id), "UI close path prompted")
        XCTAssertTrue(store.documents.isEmpty)

        let second = store.newUntitled()
        second.text = "dirty"
        second.isDirty = true
        XCTAssertTrue(store.close(second.id), "⌘W close path prompted")
        XCTAssertTrue(store.documents.isEmpty)
    }

    /// D6: launching by double-clicking a file in Finder now opens the launch
    /// file FIRST and restores the session after, so `restoreSessionTabs` has to
    /// be safe with documents already open: it must not duplicate a tab, must
    /// not steal the focus the launch file was given, and must leave the stored
    /// session describing every open tab.
    func testRestoreSessionTabsIsSafeAfterALaunchFileIsOpen() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionFile = directory.appendingPathComponent("session.txt")
        let launchFile = directory.appendingPathComponent("launch.txt")
        try "session\n".write(to: sessionFile, atomically: true, encoding: .utf8)
        try "launch\n".write(to: launchFile, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let previousOpen = defaults.stringArray(forKey: "sheeptext.session.openFiles")
        let previousActive = defaults.string(forKey: "sheeptext.session.activeFile")
        defer {
            defaults.set(previousOpen, forKey: "sheeptext.session.openFiles")
            defaults.set(previousActive, forKey: "sheeptext.session.activeFile")
        }
        // Both files were open last time; the launch file was also one of them.
        defaults.set([sessionFile.path, launchFile.path], forKey: "sheeptext.session.openFiles")
        defaults.set(sessionFile.path, forKey: "sheeptext.session.activeFile")

        // The launch order the app uses: restore first, then open what the user
        // double-clicked. (Opening first cannot work — `documents.didSet` calls
        // persistSession, which overwrites the remembered session with the one
        // launch file before anything gets a chance to read it.)
        let store = DocumentStore()
        store.restoreSessionTabs()
        XCTAssertEqual(store.documents.count, 2, "session did not come back")

        store.openExternalFileURLs([launchFile])
        XCTAssertEqual(store.documents.count, 2, "the launch file opened a second tab onto the same file")
        XCTAssertEqual(store.activeDocument?.url?.canonicalFileURL, launchFile.canonicalFileURL)
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "sheeptext.session.openFiles") ?? []),
            Set([sessionFile.path, launchFile.path]),
            "the stored session no longer lists every open tab"
        )

        // Safe with documents already open, and a no-op the second time.
        defaults.set([sessionFile.path, launchFile.path], forKey: "sheeptext.session.openFiles")
        let activeBefore = store.activeDocumentID
        store.restoreSessionTabs()
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.activeDocumentID, activeBefore, "restore stole focus")
    }
}

// MARK: - D8 / S13 / D19 / D20 / D26 smaller findings

@MainActor
final class DocStoreSmallFindingTests: XCTestCase {

    /// D19: the byte scan has to agree with the old
    /// `components(separatedBy:).prefix(400)` + Character loop, on every line
    /// ending and on the edges.
    func testIndentationDetectionMatchesTheOldSplitBasedScan() {
        func reference(_ text: String, allowSpaces2: Bool) -> TextIndentation {
            var tabLines = 0, space2 = 0, space4 = 0, space8 = 0
            for line in text.components(separatedBy: "\n").prefix(400) {
                var spaces = 0
                var sawTab = false
                for character in line {
                    if character == "\t" { sawTab = true; break }
                    if character == " " { spaces += 1; continue }
                    break
                }
                if sawTab { tabLines += 1 }
                else if spaces >= 8, spaces % 8 == 0 { space8 += 1 }
                else if spaces >= 4, spaces % 4 == 0 { space4 += 1 }
                else if spaces >= 2, spaces % 2 == 0 { space2 += 1 }
            }
            let spaceLines = space2 + space4 + space8
            if tabLines > spaceLines { return .tabs }
            if space8 > space4, space8 > space2 { return .spaces8 }
            if allowSpaces2, space2 > space4 { return .spaces2 }
            return .spaces4
        }

        let cases: [String] = [
            "",
            "no indent at all\n",
            "\tone\n\ttwo\n\tthree\n",
            "    four\n    four\n        eight\n",
            "        eight\n        eight\n        eight\n",
            "  two\n  two\n  two\n",
            "  two\r\n  two\r\n\tmixed\r\n",
            "   \t odd\n  \n\n    ok\n",
            String(repeating: "    indented line\n", count: 500)
                + String(repeating: "\ttabbed line\n", count: 500),
            "trailing without newline    "
        ]
        for text in cases {
            for allowSpaces2 in [false, true] {
                XCTAssertEqual(
                    TextIndentation.detect(in: text, allowSpaces2: allowSpaces2),
                    reference(text, allowSpaces2: allowSpaces2),
                    "differs for \(text.debugDescription) allowSpaces2=\(allowSpaces2)"
                )
            }
        }
    }

    /// D20: same for the line-ending byte state machine.
    func testLineEndingDetectionMatchesTheOldUTF16Scan() {
        func reference(_ text: String) -> TextLineEnding {
            var lf = 0, crlf = 0, cr = 0
            let ns = text as NSString
            var index = 0
            while index < ns.length {
                let character = ns.character(at: index)
                if character == 13 {
                    if index + 1 < ns.length, ns.character(at: index + 1) == 10 { crlf += 1; index += 2 }
                    else { cr += 1; index += 1 }
                } else if character == 10 { lf += 1; index += 1 }
                else { index += 1 }
            }
            if crlf >= lf, crlf >= cr, crlf > 0 { return .crlf }
            if cr > lf, cr > 0 { return .cr }
            return .lf
        }

        let cases: [String] = [
            "", "no breaks", "a\nb\n", "a\r\nb\r\n", "a\rb\r", "a\r", "\r\n",
            "mixed\na\r\nb\rc\n", "\r\r\n\r", "ไทย\r\nไทย\r\n", "emoji 🐑\nnext\n"
        ]
        for text in cases {
            XCTAssertEqual(TextLineEnding.detect(in: text), reference(text),
                           "differs for \(text.debugDescription)")
        }
    }

    /// The early stop must not change a decisive vote on a big file.
    func testLineEndingDetectionStopsEarlyWithTheSameAnswer() {
        let crlf = String(repeating: "line\r\n", count: 20_000)
        XCTAssertEqual(TextLineEnding.detect(in: crlf), .crlf)
        let lf = String(repeating: "line\n", count: 20_000)
        XCTAssertEqual(TextLineEnding.detect(in: lf), .lf)
    }

    /// S13: .jsx is JavaScript. (.tsx stays on the TypeScript grammar
    /// deliberately — see the comment at the switch.)
    func testJSXDetectsAsJavaScript() {
        XCTAssertEqual(LanguageDetector.detect(for: URL(fileURLWithPath: "/a/App.jsx")), "javascript")
        XCTAssertEqual(LanguageDetector.detect(for: URL(fileURLWithPath: "/a/App.tsx")), "typescript")
    }

    /// D26: `FileNode.id` was a fresh UUID per scan, so every `refreshTree()`
    /// produced a tree SwiftUI considered entirely new — the outline rebuilt and
    /// every expanded folder collapsed.
    func testFileNodeIdentityIsStableAcrossScans() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-nodeid-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "a".write(to: nested.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = FileNode.flatten(FileNode.scan(at: root))
        let second = FileNode.flatten(FileNode.scan(at: root))
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first, second)
    }

    /// D8: reopening with an explicit encoding never set `hasBOM`, so a BOM'd
    /// file lost its BOM on the next save.
    func testReopenWithEncodingRestoresTheBOMFlag() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-reopen-\(UUID().uuidString).txt")
        try (Data([0xEF, 0xBB, 0xBF]) + Data("hello\n".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DocumentStore()
        guard let doc = store.open(url: url, rememberRecent: false, showError: false) else {
            return XCTFail("could not open")
        }
        doc.hasBOM = false          // pretend it was lost
        store.reopenDocument(doc.id, with: .utf8)
        XCTAssertTrue(doc.hasBOM)
        XCTAssertEqual(doc.text, "hello\n")
    }
}

// MARK: - D16 security scope ownership

final class SecurityScopeOwnershipTests: XCTestCase {

    /// D16: the table was a `Set<String>` of paths, so the second `prepare` of a
    /// path skipped `startAccessing` and returned a URL instance that had never
    /// been granted anything — it worked only because the first instance was
    /// still holding the scope somewhere else in the process. The owning
    /// instance is stored and returned now.
    func testPrepareReturnsTheInstanceThatOwnsTheScope() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-scope-\(UUID().uuidString).txt")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SecurityScopedResourceAccess.startAccessing(url)
        let second = SecurityScopedResourceAccess.prepare(
            URL(fileURLWithPath: url.path),
            bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey,
            shouldRemember: false
        )
        // Both name the same file, and whichever instance owns a live scope is
        // the one handed back for I/O.
        XCTAssertEqual(first.canonicalFileURL, second.canonicalFileURL)
        XCTAssertEqual(
            SecurityScopedResourceAccess.restore(
                path: url.path,
                bookmarkKey: SecurityScopedResourceAccess.fileBookmarksKey
            ).canonicalFileURL,
            first.canonicalFileURL
        )
    }
}
