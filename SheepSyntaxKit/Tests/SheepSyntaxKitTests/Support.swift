import XCTest
@testable import SheepSyntaxKit

/// Renders a run list as `text«scope»` pairs, one per run, for readable
/// failures: `func«keyword» greet«function»`.
func tokens(_ source: String, _ language: SyntaxLanguage) -> [String] {
    let units = Array(source.utf16)
    return SyntaxHighlighter.runs(for: source, language: language).map { run in
        let text = String(decoding: units[run.location..<run.end], as: UTF16.self)
        return "\(text)«\(run.scope.captureName)»"
    }
}

/// The scope painted over the first occurrence of `needle` (its first unit).
func scope(of needle: String, in source: String, _ language: SyntaxLanguage, occurrence: Int = 0) -> SyntaxScope {
    let units = Array(source.utf16)
    let target = Array(needle.utf16)
    var found = -1
    var seen = 0
    var index = 0
    while index + target.count <= units.count {
        if Array(units[index..<index + target.count]) == target {
            if seen == occurrence { found = index; break }
            seen += 1
        }
        index += 1
    }
    precondition(found >= 0, "\(needle) not in source")
    for run in SyntaxHighlighter.runs(for: source, language: language) where run.location <= found && found < run.end {
        return run.scope
    }
    return .none
}
