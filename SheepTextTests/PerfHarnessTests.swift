//
//  PerfHarnessTests.swift
//  Before/after performance harness. Each test prints one `PERF {...}` JSON
//  line per workload; grep them out of the xcodebuild log and diff the medians.
//  Checksums must match across runs — a faster number with a different
//  checksum is a behaviour change, not an optimisation.
//

import AppKit
import XCTest
@testable import SheepText

@MainActor
final class PerfHarnessTests: XCTestCase {

    // MARK: - Harness

    private func measureWorkload(
        _ name: String,
        samples: Int = 7,
        iterations: Int = 1,
        _ body: () -> Int
    ) {
        PerfHarness.measure(name, samples: samples, iterations: iterations, body)
    }

    // MARK: - Fixtures

    private func ciscoConfig(lines: Int, ending: String) -> [String] {
        (0..<lines).map { i -> String in
            switch i % 5 {
            case 0: return "interface GigabitEthernet1/0/\(i)"
            case 1: return " description user-port-\(i)"
            case 2: return " switchport access vlan \(i % 4094 + 1)"
            case 3: return " spanning-tree portfast"
            default: return "!"
            }
        }
    }

    private func swiftSource(chars: Int) -> String {
        let line = "func value(_ input: Int) -> Int { let result = input * 2; return result } // probe 0\n"
        return String(repeating: line, count: chars / (line as NSString).length)
    }

    private func markdownSource(chars: Int) -> String {
        let block = "# Heading\n\nSome *emphasis* and `code` here.\n\n```swift\nlet x = 1\n```\n\n- item one\n- item two\n\n"
        return String(repeating: block, count: chars / (block as NSString).length)
    }

    // MARK: - Compare pipeline

    func testPerfCompareDetailed1500() {
        let left = ciscoConfig(lines: 1500, ending: "\n")
        var right = left
        for i in stride(from: 7, to: right.count, by: 20) { right[i] += " changed" }
        // move a 20-line block from near the top to the bottom
        let block = Array(right[100..<120])
        right.removeSubrange(100..<120)
        right.append(contentsOf: block)
        right.insert(contentsOf: (0..<10).map { "class-map match-any COS\($0)" }, at: 700)
        let l = left.joined(separator: "\n"), r = right.joined(separator: "\r\n")
        measureWorkload("compare_detailed_cisco_1500", samples: 5) {
            CompareBenchmarkSeam.rowHistogram(left: l, right: r).reduce(0, &+)
        }
    }

    func testPerfCompareDetailed3000Fallback() {
        let left = ciscoConfig(lines: 3000, ending: "\n")
        var right = left
        for i in stride(from: 11, to: right.count, by: 50) { right[i] += " changed" }
        right.insert(contentsOf: (0..<5).map { "vlan \(4000 + $0)" }, at: 1500)
        let l = left.joined(separator: "\n"), r = right.joined(separator: "\n")
        measureWorkload("compare_detailed_cisco_3000", samples: 5) {
            CompareBenchmarkSeam.rowHistogram(left: l, right: r).reduce(0, &+)
        }
    }

    func testPerfCompareLiveEdit1500() {
        let left = ciscoConfig(lines: 1500, ending: "\n")
        var right = left
        for i in stride(from: 7, to: right.count, by: 20) { right[i] += " changed" }
        let l = left.joined(separator: "\n"), r = right.joined(separator: "\n")
        measureWorkload("compare_liveEdit_cisco_1500", samples: 5) {
            CompareBenchmarkSeam.rowHistogram(left: l, right: r, liveEdit: true).reduce(0, &+)
        }
    }

    func testPerfTextComparatorLarge() {
        let left = ciscoConfig(lines: 20_000, ending: "\n")
        var right = left
        for i in stride(from: 3, to: right.count, by: 500) { right[i] += " changed" }
        let l = left.joined(separator: "\n"), r = right.joined(separator: "\n")
        measureWorkload("text_comparator_20000_lines", samples: 5) {
            switch TextComparator.compare(l, r, options: CompareOptions()) {
            case .match: return 1
            case .cancelled: return -1
            case .mismatch(let s): return s.added &+ s.removed &+ s.changed &+ s.blocks.count
            }
        }
    }

    // MARK: - Syntax engine

    func testPerfSyntaxCleanSwift100k() {
        let text = swiftSource(chars: 100_000)
        measureWorkload("syntax_clean_swift_100k", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "swift", isDark: true)?.length ?? -1
        }
    }

    func testPerfSyntaxIncrementalSwift100k() {
        let base = swiftSource(chars: 100_000)
        let id = UUID()
        _ = SyntaxEngine.shared.highlightImmediately(text: base, language: "swift", isDark: true, documentID: id)
        var counter = 0
        measureWorkload("syntax_incremental_swift_100k", samples: 7, iterations: 5) {
            counter += 1
            let edited = base.replacingOccurrences(of: "probe 0", with: "probe \(counter)", options: [], range: base.range(of: "probe 0"))
            return SyntaxEngine.shared.highlightImmediately(text: edited, language: "swift", isDark: true, documentID: id)?.length ?? -1
        }
        SyntaxEngine.shared.discardSession(for: id)
    }

    func testPerfSyntaxCiscoRegex5000() {
        let text = ciscoConfig(lines: 5000, ending: "\n").joined(separator: "\n")
            + "\nvlan 10,20,30-40,306s\nspanning-tree mode rpvsts\n"
        measureWorkload("syntax_cisco_regex_5000_lines", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "cisco_ios", isDark: true)?.length ?? -1
        }
    }

    func testPerfSyntaxMarkdown50k() {
        let text = markdownSource(chars: 50_000)
        measureWorkload("syntax_markdown_50k", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "markdown", isDark: true)?.length ?? -1
        }
    }

    func testPerfSyntaxCleanJSON200k() {
        let entry = "  {\"id\": 1, \"name\": \"item\", \"tags\": [\"a\", \"b\"], \"nested\": {\"ok\": true, \"n\": 3.5}},\n"
        let text = "[\n" + String(repeating: entry, count: 200_000 / (entry as NSString).length) + "  {}\n]\n"
        measureWorkload("syntax_clean_json_200k", samples: 5) {
            SyntaxEngine.shared.highlightImmediately(text: text, language: "json", isDark: false)?.length ?? -1
        }
    }

    // MARK: - Line index / folding

    func testPerfTextLineIndex() {
        let text = ciscoConfig(lines: 20_000, ending: "\n").joined(separator: "\r\n") as NSString
        let offsets = stride(from: 0, to: text.length, by: text.length / 200).map { $0 }
        measureWorkload("textlineindex_lineColumn_200_lookups", samples: 7) {
            offsets.reduce(0) { acc, off in
                let lc = TextLineIndex.lineColumn(in: text, at: off)
                return acc &+ lc.line &+ lc.column
            }
        }
        measureWorkload("textlineindex_lineNumbers_batch_200", samples: 7) {
            TextLineIndex.lineNumbers(in: text, at: offsets).reduce(0, &+)
        }
    }

    func testPerfFoldableRanges() {
        let text = swiftSource(chars: 200_000).replacingOccurrences(of: "{ let", with: "{\n    let") as NSString
        let manager = FoldingManager()
        measureWorkload("folding_foldableRanges_swift_200k", samples: 5) {
            manager.foldableRanges(in: text).count
        }
    }

    // MARK: - File IO

    func testPerfDecodeAndLineEnding() {
        let body = ciscoConfig(lines: 100_000, ending: "\n").joined(separator: "\r\n") + "\r\n"
        let data = Data(body.utf8)
        measureWorkload("decode_utf8_crlf_3MB", samples: 5) {
            TextFileIO.decode(data: data).text.utf16.count
        }
        measureWorkload("lineending_detect_3MB", samples: 5) {
            TextLineEnding.detect(in: body) == .crlf ? 1 : 0
        }
        measureWorkload("looksBinary_3MB", samples: 7) {
            TextFileIO.looksBinary(data) ? 1 : 0
        }
    }

    // MARK: - Find in Files

    func testPerfFindInFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheeptext-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = ciscoConfig(lines: 500, ending: "\n").joined(separator: "\n")
        for i in 0..<200 {
            let dir = root.appendingPathComponent("dir\(i % 10)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: dir.appendingPathComponent("config\(i).cfg"), atomically: true, encoding: .utf8)
        }
        measureWorkload("filenode_scan_200_files", samples: 5) {
            FileNode.flatten(FileNode.scan(at: root)).count
        }
        let tree = FileNode.scan(at: root)
        let options = FindInFilesOptions(query: "vlan 123", caseSensitive: false, wholeWord: false, useRegex: false)
        measureWorkload("findinfiles_200_files_x_500_lines", samples: 5) {
            (try? FindInFilesEngine.search(root: root, tree: tree, options: options))?.matches.count ?? -1
        }
        let regexOptions = FindInFilesOptions(query: "vlan\\s+12[3-4]", caseSensitive: false, wholeWord: false, useRegex: true)
        measureWorkload("findinfiles_regex_200_files", samples: 5) {
            (try? FindInFilesEngine.search(root: root, tree: tree, options: regexOptions))?.matches.count ?? -1
        }
    }
}
