import XCTest

/// A CRLF pair is a single Swift `Character` that does not equal `"\n"`, so
/// Character-level line handling silently does nothing on a CRLF file. That
/// mistake has been made and fixed six separate times in this codebase:
/// `LineHashing.splitLines` (a 1500-line compare took 29 s and reported the
/// whole file changed), `LargeFilePolicy.lineCount` (a 500,000-line file
/// counted as 1), `FoldingManager.foldableRanges` (folding did not work at all
/// on CRLF), `EditorBridge.getCurrentLine`, `FoldRegion`'s hidden-line count,
/// and `FoldingManager.fold`'s guard.
///
/// Each was fixed where it was found. This scans for the shapes instead, so the
/// seventh one fails a test the day it is written rather than in a bug report
/// about a Windows file.
///
/// The offending code always *looks* right, compiles without a warning, and
/// works on every LF file — which is why review keeps missing it.
enum LineEndingHygiene {

    struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let source: String
        let reason: String

        var description: String { "\(file):\(line): \(reason)\n    \(source)" }
    }

    /// Shapes that are wrong in this codebase no matter the surrounding code.
    private static let banned: [(needle: String, reason: String)] = [
        (#".contains("\n")"#,
         #"`contains("\n")` compares Characters, so it is false for CRLF — and it is worse than that: it answers *true* for a string bridged from NSTextStorage and *false* for a native Swift String, so behaviour depends on where the value came from. Search `unicodeScalars`, or count UTF-8 0x0A."#),
        (#".contains("\r\n")"#,
         #"Do not special-case CRLF. Handle line breaks at the scalar or UTF-8 level and both endings fall out for free."#),
        (#"split(separator: "\n")"#,
         #"`split(separator:)` compares Characters, so it never splits CRLF text at all — the whole file comes back as one element. Use `LineHashing.splitLines`, which splits on the newline scalar."#),
        (#"split(separator: "\r\n")"#,
         #"Use `LineHashing.splitLines`."#),
    ]

    /// Every shape above is only about *Character-level* handling. The same call
    /// on `unicodeScalars` or `utf8` is correct, so a line that mentions one of
    /// these is left alone. `// line-ending-checked` is the escape hatch for
    /// anything this cannot see.
    private static let scalarEvidence = [
        "utf8", "utf16", "unicodeScalars", "scalar", "Scalar",
        "byte", "0x0A", "UInt8", "unichar", "character(at:", "UTF16",
    ]

    static func violations(in source: String, path: String) -> [Violation] {
        var found: [Violation] = []
        for (index, rawLine) in source.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Comments describe the trap on purpose all over this codebase.
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            if trimmed.contains("line-ending-checked") { continue }

            let looksScalar = scalarEvidence.contains { rawLine.contains($0) }
            if looksScalar { continue }

            for rule in banned where rawLine.contains(rule.needle) {
                found.append(Violation(file: path, line: index + 1,
                                       source: trimmed, reason: rule.reason))
            }

            if rawLine.contains(#"== "\n""#) || rawLine.contains(#"!= "\n""#) {
                found.append(Violation(
                    file: path, line: index + 1, source: trimmed,
                    reason: #"Comparing against "\n" with nothing on the line to show the operand is a scalar, byte or UTF-16 unit. If it is a Character, CRLF will not match. Compare over `unicodeScalars`/`utf8`, or add `// line-ending-checked` if this really is safe."#
                ))
            }
        }
        return found
    }
}

final class LineEndingHygieneTests: XCTestCase {

    /// `#filePath` is this file's location at compile time, so the app sources
    /// sit at ../SheepText relative to the test directory.
    private var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/SheepTextTests/LineEndingHygieneTests.swift
            .deletingLastPathComponent()          // …/SheepTextTests
            .deletingLastPathComponent()          // …/SheepText  (the Xcode project directory)
            .appendingPathComponent("SheepText", isDirectory: true)
    }

    func testAppSourcesHandleLineBreaksBelowTheCharacterLevel() throws {
        let root = appSourceRoot
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("Sources not reachable from \(root.path) — building from a different layout.")
        }

        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return XCTFail("could not walk \(root.path)") }

        var violations: [LineEndingHygiene.Violation] = []
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            violations += LineEndingHygiene.violations(
                in: source,
                path: url.lastPathComponent
            )
        }

        XCTAssertGreaterThan(scanned, 20, "expected to scan the app's sources, found \(scanned) files")
        XCTAssertTrue(
            violations.isEmpty,
            "Character-level line-break handling found:\n\n"
            + violations.map(\.description).joined(separator: "\n\n")
        )
    }

    /// The scanner is the thing being trusted here, so it gets its own tests.
    /// A guard that silently matches nothing is worse than no guard.
    func testScannerCatchesEachKnownShape() {
        let bad = #"""
        let hasBreak = text.contains("\n")
        let lines = text.split(separator: "\n")
        let count = text.reduce(into: 0) { c, ch in if ch == "\n" { c += 1 } }
        let crlf = text.contains("\r\n")
        """#
        let found = LineEndingHygiene.violations(in: bad, path: "Bad.swift")
        XCTAssertEqual(found.count, 4, "expected one hit per line, got:\n\(found)")
        XCTAssertEqual(Set(found.map(\.line)), [1, 2, 3, 4])
    }

    func testScannerLeavesCorrectCodeAlone() {
        let good = #"""
        let count = text.utf8.reduce(into: 0) { c, b in if b == 0x0A { c += 1 } }
        let lines = LineHashing.splitLines(text)
        let parts = text.components(separatedBy: "\n")
        let hasBreak = text.unicodeScalars.contains("\n")
        if scalar == "\n" { rows += 1 }
        // text.contains("\n") in a comment is describing the trap, not doing it
        let n = ns.character(at: index) == "\n" ? 1 : 0
        let allowed = text.contains("\n")  // line-ending-checked
        """#
        let found = LineEndingHygiene.violations(in: good, path: "Good.swift")
        XCTAssertTrue(found.isEmpty, "false positives:\n\(found.map(\.description).joined(separator: "\n"))")
    }
}
