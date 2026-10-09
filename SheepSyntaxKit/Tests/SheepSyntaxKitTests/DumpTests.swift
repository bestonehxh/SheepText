import XCTest
@testable import SheepSyntaxKit

/// Not a test: `SHEEPSYNTAX_DUMP=1 swift test --filter DumpTests` renders
/// every sample with its runs inline, for reading.
final class DumpTests: XCTestCase {
    func testDump() throws {
        guard let path = ProcessInfo.processInfo.environment["SHEEPSYNTAX_DUMP"] else { throw XCTSkip("set SHEEPSYNTAX_DUMP") }
        var out = ""
        for (language, sample) in Samples.grammars {
            out += "===== \(language) =====\n"
            let units = Array(sample.utf16)
            var cursor = 0
            var rendered: [UInt16] = []
            for run in SyntaxHighlighter(grammar: language).update(sample).runs {
                rendered += units[cursor..<run.location]
                rendered += Array("«".utf16) + units[run.location..<run.end] + Array("|\(run.scope.captureName)»".utf16)
                cursor = run.end
            }
            rendered += units[cursor...]
            out += String(decoding: rendered, as: UTF16.self) + "\n\n"
        }
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
