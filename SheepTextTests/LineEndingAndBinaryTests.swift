import AppKit
import XCTest
@testable import SheepText

/// CRLF is one Character in Swift and it does not equal "\n". Every regression
/// in this file is the same mistake at a different layer, so they are kept
/// together: if one of these fails, look for the others.
@MainActor
final class LineEndingTests: XCTestCase {

    private let lfSource   = "func a() {\n    let x = 1\n    let y = 2\n}\n"
    private let crlfSource = "func a() {\r\n    let x = 1\r\n    let y = 2\r\n}\r\n"

    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: 5000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return storage
    }

    private func foldFirstRegion(in source: String) -> (FoldingManager, NSTextStorage)? {
        let manager = FoldingManager()
        let storage = makeStorage(source)
        guard let range = manager.foldableRanges(in: storage.string as NSString).first
        else { return nil }
        manager.fold(range: range, in: storage)
        return (manager, storage)
    }

    func testFoldableRangesAreFoundOnBothLineEndings() {
        XCTAssertFalse(FoldingManager().foldableRanges(in: lfSource as NSString).isEmpty, "LF")
        XCTAssertFalse(FoldingManager().foldableRanges(in: crlfSource as NSString).isEmpty, "CRLF")
    }

    func testFoldCollapsesOnBothLineEndings() {
        for (label, source) in [("LF", lfSource), ("CRLF", crlfSource)] {
            guard let (manager, storage) = foldFirstRegion(in: source) else {
                return XCTFail("\(label): no foldable range")
            }
            XCTAssertEqual(manager.regions.count, 1, "\(label): nothing was folded")
            XCTAssertLessThan(storage.length, (source as NSString).length, "\(label)")
        }
    }

    /// `LineNumberRulerView.foldLineSpans` reads `hiddenLineCount` to place the
    /// modified-since-save bars for rows a fold is hiding. It used to count with
    /// `originalText.reduce { $0 == "\n" }`, which returns 0 for CRLF — so every
    /// fold dropped out of the map and the bars landed on the wrong rows.
    func testFoldedRegionReportsItsHiddenLineCountOnBothLineEndings() {
        for (label, source) in [("LF", lfSource), ("CRLF", crlfSource)] {
            guard let (manager, _) = foldFirstRegion(in: source),
                  let region = manager.regions.first else {
                return XCTFail("\(label): no region")
            }
            let realNewlines = region.originalText.utf8.filter { $0 == 0x0A }.count
            XCTAssertEqual(region.hiddenLineCount, realNewlines, "\(label)")
            XCTAssertEqual(region.hiddenLineCount, 3, "\(label)")
        }
    }

    /// The fold preview reads "{ N lines }". N came from the same kind of count.
    func testUnfoldRestoresTheOriginalTextOnBothLineEndings() {
        for (label, source) in [("LF", lfSource), ("CRLF", crlfSource)] {
            guard let (manager, storage) = foldFirstRegion(in: source),
                  let region = manager.regions.first else {
                return XCTFail("\(label): no region")
            }
            manager.unfold(at: region.displayLocation, in: storage)
            XCTAssertEqual(storage.string, source, "\(label): unfold did not restore the text")
        }
    }
}

@MainActor
final class BinaryFileDetectionTests: XCTestCase {

    func testPlainTextIsNotFlagged() {
        let decoded = TextFileIO.decode(data: Data("hello\r\nสวัสดี\n".utf8))
        XCTAssertFalse(decoded.looksBinary)
        XCTAssertEqual(decoded.text, "hello\r\nสวัสดี\n")
    }

    /// The decode chain never fails — its last resort is Windows-1252 — so a
    /// binary file opens as mangled text. Saving that back destroys the
    /// original, which is why the flag has to travel with the result.
    func testBinaryPayloadIsFlagged() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]  // PNG header
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])
        bytes.append(contentsOf: Array(repeating: 0x00, count: 200))
        let decoded = TextFileIO.decode(data: Data(bytes))
        XCTAssertTrue(decoded.looksBinary)
    }

    /// UTF-16 spells every ASCII character with a NUL byte, so the NUL test
    /// calls an ordinary text file binary unless the encoding is accounted for.
    func testUTF16TextIsNotFlagged() {
        let text = "let value = 1\nlet other = 2\n"

        let withBOM = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        let decodedBOM = TextFileIO.decode(data: withBOM)
        XCTAssertFalse(decodedBOM.looksBinary, "UTF-16LE with BOM")
        XCTAssertEqual(decodedBOM.text, text)

        XCTAssertTrue(TextEncoding.utf16LE.usesWideCodeUnits)
        XCTAssertFalse(TextEncoding.utf8.usesWideCodeUnits)
    }

    func testFindInFilesAndOpenShareOneBinaryHeuristic() {
        XCTAssertTrue(TextFileIO.looksBinary(Data([0x41, 0x00, 0x42])))
        XCTAssertFalse(TextFileIO.looksBinary(Data("plain".utf8)))
    }
}
