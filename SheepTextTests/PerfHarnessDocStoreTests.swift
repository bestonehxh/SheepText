//
//  PerfHarnessDocStoreTests.swift
//  Before/after workloads for the document / file / IO layer.
//
//  Written against the API as it exists BEFORE the audit fixes, because the
//  orchestrator runs this class on the pre-fix commit too. Nothing here may
//  reference a symbol introduced by a fix.
//
//  Checksums are stable across a pure optimisation. Two of them move on
//  purpose and are called out in the fix report:
//    - decode_detect_nonutf8_5MB: D2 removes the endian-ambiguous UTF-16/32
//      entries from the detection chain, so a Windows-1252 file stops being
//      decoded as big-endian UTF-16. The checksum is the decoded UTF-16 length,
//      which is exactly what that bug halved.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessDocStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// ~10 MB of indented, LF-terminated source.
    private static let indentedSource: String = {
        let block = """
            func value(_ input: Int) -> Int {
                let result = input * 2
                    let nested = result + 1
                return nested
            }

            """
        let blockBytes = (block as NSString).length
        return String(repeating: block, count: 10_000_000 / blockBytes)
    }()

    /// ~4 MB of Thai text — UTF-16 length differs from UTF-8 length, so there
    /// is no O(1) shortcut for `utf16.count`.
    private static let thaiSource: String = {
        var lines: [String] = []
        var bytes = 0
        var i = 0
        while bytes < 4_000_000 {
            let line = "    สวัสดีครับ ค่าที่ \(i) คือ someFunction"
            bytes += line.utf8.count + 1
            lines.append(line)
            i += 1
        }
        return lines.joined(separator: "\n")
    }()

    /// 5 MB of Windows-1252 bytes: high-bit characters that are not valid UTF-8,
    /// so the whole detection chain runs.
    private static let windows1252Data: Data = {
        let line = "Caf\u{E9} r\u{E9}sum\u{E9} na\u{EF}ve \u{93}quoted\u{94} \u{97} value 42\n"
        var unit: [UInt8] = []
        for scalar in line.unicodeScalars { unit.append(UInt8(scalar.value & 0xFF)) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(5_000_000 + unit.count)
        while bytes.count < 5_000_000 { bytes.append(contentsOf: unit) }
        return Data(bytes)
    }()

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sheeptext-perf-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Workloads

    /// TextIndentation.detect only looks at the first 400 lines but used to
    /// materialise every line of the file to get them.
    func testPerfIndentationDetect10MB() {
        let text = Self.indentedSource
        PerfHarness.measure("indentation_detect_10MB", samples: 5, iterations: 1) {
            var checksum = 0
            for _ in 0..<3 {
                checksum &+= TextIndentation.detect(in: text).rawValue.count
            }
            return checksum
        }
    }

    /// TextLineEnding.detect runs on every open, reload and indentation change.
    func testPerfLineEndingDetect10MB() {
        let text = Self.indentedSource
        PerfHarness.measure("lineending_detect_10MB", samples: 5, iterations: 1) {
            var checksum = 0
            for _ in 0..<3 {
                checksum &+= TextLineEnding.detect(in: text).rawValue.count
            }
            return checksum
        }
    }

    /// `Document.text.didSet`. The editor hands over a freshly bridged NSString
    /// (`textStorage.string`) on every keystroke, so anything that walks the
    /// characters costs a full transcode of the document.
    func testPerfDocumentTextDidSetThai() {
        let storage = NSTextStorage(string: Self.thaiSource)
        let document = Document(url: nil, initialText: "", encoding: .utf8, hasBOM: false)
        PerfHarness.measure("text_didSet_thai_4MB_x50", samples: 5, iterations: 1) {
            var checksum = 0
            for _ in 0..<50 {
                document.text = storage.string   // fresh bridge, like fullText(from:)
                checksum &+= document.textUTF16Count
            }
            return checksum
        }
    }

    /// TextFileIO.decode over a file that is not UTF-8: the whole fallback
    /// chain is tried, each entry decoding the entire file.
    func testPerfDecodeDetectNonUTF8() {
        let data = Self.windows1252Data
        PerfHarness.measure("decode_detect_nonutf8_5MB", samples: 5, iterations: 1) {
            let decoded = TextFileIO.decode(data: data)
            return (decoded.text as NSString).length
        }
    }

    /// Find in Files over 30 files with 40 matches each. Beyond the raw scan
    /// cost this exercises the per-file security-scope resolve and the
    /// per-line substring + regex.
    func testPerfFindInFiles2000Matches() throws {
        let root = try makeTemporaryDirectory("findinfiles")
        defer { try? FileManager.default.removeItem(at: root) }

        for fileIndex in 0..<30 {
            var lines: [String] = []
            for lineIndex in 0..<40 {
                lines.append("let padding\(lineIndex) = 0")
                lines.append("needle marker \(fileIndex)-\(lineIndex)")
            }
            let name = String(format: "file-%03d.swift", fileIndex)
            try lines.joined(separator: "\n").write(
                to: root.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        let tree = FileNode.scan(at: root)
        let options = FindInFilesOptions(
            query: "needle",
            caseSensitive: true,
            wholeWord: false,
            useRegex: false
        )

        PerfHarness.measure("findinfiles_2000_matches", samples: 5, iterations: 1) {
            guard let summary = try? FindInFilesEngine.search(root: root, tree: tree, options: options)
            else { return -1 }
            // The first 300 hits are identical before and after the cap fix
            // (same file order, same line order), so this stays stable while
            // the total count changes from 500 to 1000.
            var checksum = 0
            for match in summary.matches.prefix(300) {
                checksum &+= match.lineNumber &* 31 &+ match.column
            }
            return checksum
        }
    }

    /// Sidebar tree scan. Every refresh rebuilds this.
    func testPerfFileNodeScan2000Files() throws {
        let root = try makeTemporaryDirectory("filenodescan")
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("x".utf8)
        for directoryIndex in 0..<20 {
            let directory = root.appendingPathComponent(
                String(format: "dir-%02d", directoryIndex),
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileIndex in 0..<100 {
                let name = String(format: "file-%03d.txt", fileIndex)
                try payload.write(to: directory.appendingPathComponent(name))
            }
        }

        PerfHarness.measure("filenode_scan_2000_files", samples: 5, iterations: 1) {
            FileNode.flatten(FileNode.scan(at: root)).count
        }
    }
}
