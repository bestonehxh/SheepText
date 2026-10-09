import XCTest
@testable import SheepSyntaxKit

/// One assertion per behaviour worth keeping. The samples' full renderings
/// are for reading (DumpTests); these are for not regressing.
final class LanguageTests: XCTestCase {
    func testIdentifiersResolve() {
        XCTAssertEqual(SyntaxLanguage(identifier: "Swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(identifier: "tsx"), .typescript)
        XCTAssertEqual(SyntaxLanguage(identifier: "sh"), .bash)
        XCTAssertEqual(SyntaxLanguage(identifier: "yml"), .yaml)
        XCTAssertEqual(SyntaxLanguage(identifier: "besttext_log"), .log)
        XCTAssertEqual(SyntaxLanguage(identifier: "c#"), .csharp)
        XCTAssertNil(SyntaxLanguage(identifier: "network_config"))
        XCTAssertNil(SyntaxLanguage(identifier: "brainfuck"))
    }

    func testCaptureNamesAreDottedScopes() {
        XCTAssertEqual(SyntaxScope.functionMethod.captureName, "function.method")
        XCTAssertEqual(SyntaxScope.title.captureName, "text.title")
        for scope in SyntaxScope.allCases where scope != .none {
            XCTAssertFalse(scope.captureName.isEmpty)
        }
    }

    // MARK: Swift

    func testSwift() {
        let source = """
        @MainActor func greet(_ n: Int) -> String { "a \\(n.description) b" }
        let x = items.map { $0 }.filter(isValid)
        #if DEBUG
        """
        XCTAssertEqual(scope(of: "@MainActor", in: source, .swift), .attribute)
        XCTAssertEqual(scope(of: "func", in: source, .swift), .keyword)
        XCTAssertEqual(scope(of: "greet", in: source, .swift), .function)
        XCTAssertEqual(scope(of: "Int", in: source, .swift), .typeBuiltin)
        XCTAssertEqual(scope(of: "\\(", in: source, .swift), .punctuationSpecial)
        XCTAssertEqual(scope(of: "description", in: source, .swift), .property)
        XCTAssertEqual(scope(of: " b", in: source, .swift), .string)
        XCTAssertEqual(scope(of: "map", in: source, .swift), .functionMethod)
        XCTAssertEqual(scope(of: "$0", in: source, .swift), .variableBuiltin)
        XCTAssertEqual(scope(of: "filter", in: source, .swift), .functionMethod)
        XCTAssertEqual(scope(of: "#if", in: source, .swift), .keywordDirective)
        XCTAssertEqual(scope(of: "DEBUG", in: source, .swift), .constant)
    }

    func testSwiftMultilineStringAndNestedComment() {
        let source = "let s = \"\"\"\n  a \\(b)\n  \"\"\"\n/* x /* y */ still */ let z = 1"
        XCTAssertEqual(scope(of: "  a", in: source, .swift), .string)
        XCTAssertEqual(scope(of: "still", in: source, .swift), .comment)
        XCTAssertEqual(scope(of: "let", in: source, .swift, occurrence: 1), .keyword)
    }

    // MARK: JavaScript / TypeScript

    func testJavaScriptRegexVersusDivision() {
        let source = "const r = /a+b/g; const h = total / 2 / count;"
        XCTAssertEqual(scope(of: "/a+b/g", in: source, .javascript), .stringRegex)
        XCTAssertEqual(scope(of: "2", in: source, .javascript), .number)
        XCTAssertEqual(scope(of: "count", in: source, .javascript), .none)
    }

    func testJSXAndTemplateLiterals() {
        let source = "const el = <div id=\"a\" onClick={() => go(`x${y}`)}>Hi {name}</div>;\nconst after = 1;"
        XCTAssertEqual(scope(of: "div", in: source, .javascript), .tag)
        XCTAssertEqual(scope(of: "id", in: source, .javascript), .tagAttribute)
        XCTAssertEqual(scope(of: "go", in: source, .javascript), .function)
        XCTAssertEqual(scope(of: "${", in: source, .javascript), .punctuationSpecial)
        XCTAssertEqual(scope(of: "Hi", in: source, .javascript), .none)
        XCTAssertEqual(scope(of: "const", in: source, .javascript, occurrence: 1), .keyword)
    }

    func testTypeScriptGenericsAreNotJSX() {
        let source = "const a = <T>value;\nconst f = <T,>(x: T) => x;\nconst ok = 1;"
        XCTAssertEqual(scope(of: "const", in: source, .typescript, occurrence: 2), .keyword)
        XCTAssertEqual(scope(of: "value", in: source, .typescript), .none)
    }

    // MARK: Rust / Go / C / C# / Java / Scala

    func testRust() {
        let source = "#[derive(Debug)]\nfn f<'a>(s: &'a str) { println!(\"{}\", r#\"raw\"#); let c = 'x'; }"
        XCTAssertEqual(scope(of: "#[derive", in: source, .rust), .attribute)
        XCTAssertEqual(scope(of: "'a", in: source, .rust), .label)
        XCTAssertEqual(scope(of: "println!", in: source, .rust), .functionMacro)
        XCTAssertEqual(scope(of: "r#\"raw\"#", in: source, .rust), .string)
        XCTAssertEqual(scope(of: "'x'", in: source, .rust), .character)
    }

    func testGoCapitalisation() {
        let source = "type Point struct {\n\tX, Y int\n}\nfunc (p *Point) String() string { return Point{X: 1}.Name }"
        XCTAssertEqual(scope(of: "Point", in: source, .go), .type)
        XCTAssertEqual(scope(of: "X", in: source, .go), .none)
        XCTAssertEqual(scope(of: "Point", in: source, .go, occurrence: 1), .type)
        XCTAssertEqual(scope(of: "String", in: source, .go), .function)
        XCTAssertEqual(scope(of: "Point", in: source, .go, occurrence: 2), .type)
        XCTAssertEqual(scope(of: "X", in: source, .go, occurrence: 1), .property)
    }

    func testCPreprocessor() {
        let source = "#include <stdio.h>\n#define MAX(a) (a)\nsize_t n = MAX(1);"
        XCTAssertEqual(scope(of: "#include", in: source, .c), .keywordDirective)
        XCTAssertEqual(scope(of: "<stdio.h>", in: source, .c), .string)
        XCTAssertEqual(scope(of: "MAX", in: source, .c), .functionMacro)
        XCTAssertEqual(scope(of: "size_t", in: source, .c), .typeBuiltin)
    }

    func testCSharpPascalCase() {
        let source = "public record Person(string Name);\nvar s = $\"Hi {Name}\"; Console.WriteLine(s); int Count { get; }"
        XCTAssertEqual(scope(of: "Person", in: source, .csharp), .type)
        XCTAssertEqual(scope(of: "Name", in: source, .csharp), .property)
        XCTAssertEqual(scope(of: "{", in: source, .csharp), .punctuationSpecial)
        XCTAssertEqual(scope(of: "Console", in: source, .csharp), .type)
        XCTAssertEqual(scope(of: "WriteLine", in: source, .csharp), .functionMethod)
        XCTAssertEqual(scope(of: "Count", in: source, .csharp), .property)
    }

    func testJavaImportPath() {
        let source = "import java.util.List;\nString s = obj.field;"
        XCTAssertEqual(scope(of: "java", in: source, .java), .none)
        XCTAssertEqual(scope(of: "util", in: source, .java), .none)
        XCTAssertEqual(scope(of: "List", in: source, .java), .type)
        XCTAssertEqual(scope(of: "field", in: source, .java), .property)
    }

    // MARK: Scripting languages

    func testPython() {
        let source = "@dataclass\ndef f(x: int) -> str:\n    return f\"{x!r} {{\" + print(len(x), end='')\n"
        XCTAssertEqual(scope(of: "@dataclass", in: source, .python), .attribute)
        XCTAssertEqual(scope(of: "f(", in: source, .python), .function)
        XCTAssertEqual(scope(of: "int", in: source, .python), .typeBuiltin)
        XCTAssertEqual(scope(of: "{{", in: source, .python), .stringEscape)
        XCTAssertEqual(scope(of: "print", in: source, .python), .functionBuiltin)
        XCTAssertEqual(scope(of: "end", in: source, .python), .variableParameter)
    }

    func testPythonTripleQuotedStringSpansLines() {
        let source = "x = '''\nnot code: def\n'''\ndef g(): pass"
        XCTAssertEqual(scope(of: "not code", in: source, .python), .string)
        XCTAssertEqual(scope(of: "g", in: source, .python), .function)
    }

    func testRubyHeredocAndInterpolation() {
        let source = "doc = <<~EOS\n  Hi #{name}\nEOS\nputs :sym, key: 1"
        XCTAssertEqual(scope(of: "  Hi", in: source, .ruby), .string)
        XCTAssertEqual(scope(of: "#{", in: source, .ruby), .punctuationSpecial)
        XCTAssertEqual(scope(of: "puts", in: source, .ruby), .functionBuiltin)
        XCTAssertEqual(scope(of: ":sym", in: source, .ruby), .stringSymbol)
        XCTAssertEqual(scope(of: "key:", in: source, .ruby), .stringSymbol)
    }

    func testBashCommandsAndContinuations() {
        let source = "echo \"hi $USER\" >&2\napt-get install -y \\\n  curl \\\n  git\nif [[ -f x ]]; then ls; fi"
        XCTAssertEqual(scope(of: "echo", in: source, .bash), .functionBuiltin)
        XCTAssertEqual(scope(of: "$USER", in: source, .bash), .variableSpecial)
        XCTAssertEqual(scope(of: "2", in: source, .bash), .number)
        XCTAssertEqual(scope(of: "apt-get", in: source, .bash), .function)
        XCTAssertEqual(scope(of: "curl", in: source, .bash), .none)
        XCTAssertEqual(scope(of: "git", in: source, .bash), .none)
        XCTAssertEqual(scope(of: "-f", in: source, .bash), .constant)
        XCTAssertEqual(scope(of: "ls", in: source, .bash), .function)
    }

    func testPHPIslands() {
        let source = "<p class=\"<?= $c ?>\">x</p>\n<?php\n// comment\n$a = \"v {$b->c}\";\n?>\n<b>done</b>"
        XCTAssertEqual(scope(of: "<?=", in: source, .php), .tag)
        XCTAssertEqual(scope(of: "$c", in: source, .php), .variableSpecial)
        XCTAssertEqual(scope(of: "c}", in: source, .php), .property)
        XCTAssertEqual(scope(of: "b>done", in: source, .php), .tag)
    }

    // MARK: Data and markup

    func testJSONKeysAndValues() {
        let source = "{\"k\": \"v\", \"n\": -1.5e3, \"b\": true, \"z\": null}"
        XCTAssertEqual(scope(of: "\"k\"", in: source, .json), .property)
        XCTAssertEqual(scope(of: "\"v\"", in: source, .json), .string)
        XCTAssertEqual(scope(of: "-1.5e3", in: source, .json), .number)
        XCTAssertEqual(scope(of: "true", in: source, .json), .boolean)
        XCTAssertEqual(scope(of: "null", in: source, .json), .constantBuiltin)
    }

    func testYAMLBlockScalarEndsAtDedent() {
        let source = "run: |\n  echo key: value\nnext: 1"
        XCTAssertEqual(scope(of: "echo key", in: source, .yaml), .string)
        XCTAssertEqual(scope(of: "next", in: source, .yaml), .property)
        XCTAssertEqual(scope(of: "1", in: source, .yaml), .number)
    }

    func testHTMLEmbedsScriptAndStyle() {
        let source = "<style>a { color: red; }</style><script>let x = /* c */ 1;</script><p>let</p>"
        XCTAssertEqual(scope(of: "color", in: source, .html), .property)
        XCTAssertEqual(scope(of: "let", in: source, .html), .keyword)
        XCTAssertEqual(scope(of: "/* c */", in: source, .html), .comment)
        XCTAssertEqual(scope(of: "let", in: source, .html, occurrence: 1), .none)
    }

    func testMarkdown() {
        let source = """
        Title
        =====

        - [ ] task with `code` and **bold**
        ```swift
        let x = 1 /* open
        close */
        ```
        """
        XCTAssertEqual(scope(of: "Title", in: source, .markdown), .title)
        XCTAssertEqual(scope(of: "=====", in: source, .markdown), .punctuationSpecial)
        XCTAssertEqual(scope(of: "-", in: source, .markdown), .punctuationListMarker)
        XCTAssertEqual(scope(of: "task", in: source, .markdown), .none)
        XCTAssertEqual(scope(of: "`code`", in: source, .markdown), .literal)
        XCTAssertEqual(scope(of: "**bold**", in: source, .markdown), .strong)
        XCTAssertEqual(scope(of: "swift", in: source, .markdown), .label)
        XCTAssertEqual(scope(of: "let", in: source, .markdown), .keyword)
        XCTAssertEqual(scope(of: "close", in: source, .markdown), .comment)
    }

    func testEmphasisOpenedOnOneLineClosesOnALaterOne() {
        let before = "# Title\n\nfirst line of the paragraph\nsecond line of it* and more\n\ntrailing\n"
        let after = "# Title\n\nfirst *ine of the paragraph\nsecond line of it* and more\n\ntrailing\n"
        XCTAssertEqual(scope(of: "second", in: before, .markdown), .none)
        XCTAssertEqual(scope(of: "second", in: after, .markdown), .emphasis)
        XCTAssertEqual(scope(of: "and more", in: after, .markdown), .none)
        XCTAssertEqual(scope(of: "trailing", in: after, .markdown), .none)

        let session = SyntaxHighlighter(language: .markdown)
        _ = session.update(before)
        XCTAssertEqual(session.update(after).runs, SyntaxHighlighter.runs(for: after, language: .markdown))
    }

    func testEmphasisWithNoCloserDoesNotLeak() {
        let source = "open *never closed\nnext line\n\nafter"
        XCTAssertEqual(scope(of: "never", in: source, .markdown), .none)
        XCTAssertEqual(scope(of: "next", in: source, .markdown), .none)
    }

    func testMarkdownFenceLanguagesAreCommonMark() {
        // Unclosed fences run to the end; ~~~ works; an info string may carry more than the language.
        let source = "~~~python title=\"x\"\ndef f(): pass\n"
        XCTAssertEqual(scope(of: "def", in: source, .markdown), .keyword)
    }

    func testDiffHunkCountsDecideHeaders() {
        let source = "@@ -1 +1 @@\n--- not a header\n+++ not a header\n--- a/file\n"
        XCTAssertEqual(scope(of: "--- not", in: source, .diff), .diffMinus)
        XCTAssertEqual(scope(of: "+++ not", in: source, .diff), .diffPlus)
        XCTAssertEqual(scope(of: "--- a/file", in: source, .diff), .diffHeader)
    }

    func testLogWholeWords() {
        let source = "2026-09-27 10:00:00 ERROR download failed on Gi1/0/1 vlan 10 from 10.0.0.1"
        XCTAssertEqual(scope(of: "2026", in: source, .log), .comment)
        XCTAssertEqual(scope(of: "ERROR", in: source, .log), .logError)
        XCTAssertEqual(scope(of: "download", in: source, .log), .none)
        XCTAssertEqual(scope(of: "failed", in: source, .log), .logError)
        XCTAssertEqual(scope(of: "Gi1/0/1", in: source, .log), .property)
        XCTAssertEqual(scope(of: "vlan 10", in: source, .log), .constant)
        XCTAssertEqual(scope(of: "10.0.0.1", in: source, .log), .function)
    }

    func testSQL() {
        let source = "CREATE TABLE users (id INT);\nselect count(*) from users u where u.name = 'it''s' and id = $1;"
        XCTAssertEqual(scope(of: "users", in: source, .sql), .none)
        XCTAssertEqual(scope(of: "INT", in: source, .sql), .typeBuiltin)
        XCTAssertEqual(scope(of: "select", in: source, .sql), .keyword)
        XCTAssertEqual(scope(of: "count", in: source, .sql), .function)
        XCTAssertEqual(scope(of: "name", in: source, .sql), .property)
        XCTAssertEqual(scope(of: "''", in: source, .sql), .stringEscape)
        XCTAssertEqual(scope(of: "$1", in: source, .sql), .variableParameter)
    }

    func testDockerfileRunIsBash() {
        let source = "FROM alpine AS base\nRUN apk add \\\n    curl && echo \"$HOME\"\nENV A=1"
        XCTAssertEqual(scope(of: "FROM", in: source, .dockerfile), .keyword)
        XCTAssertEqual(scope(of: "base", in: source, .dockerfile), .label)
        XCTAssertEqual(scope(of: "apk", in: source, .dockerfile), .function)
        XCTAssertEqual(scope(of: "curl", in: source, .dockerfile), .none)
        XCTAssertEqual(scope(of: "echo", in: source, .dockerfile), .functionBuiltin)
        XCTAssertEqual(scope(of: "ENV", in: source, .dockerfile), .keyword)
    }

    func testCRLFAndLoneCRLines() {
        let source = "let a = 1\r\nlet b = \"x\"\rlet c = 2"
        XCTAssertEqual(scope(of: "let", in: source, .swift, occurrence: 1), .keyword)
        XCTAssertEqual(scope(of: "let", in: source, .swift, occurrence: 2), .keyword)
        XCTAssertEqual(scope(of: "\"x\"", in: source, .swift), .string)
    }

    func testUnicodeOffsetsAreUTF16() {
        let source = "let 😀 = \"ก่า\" // é"
        let runs = SyntaxHighlighter.runs(for: source, language: .swift)
        let units = Array(source.utf16)
        let texts = runs.map { String(decoding: units[$0.location..<$0.end], as: UTF16.self) }
        XCTAssertEqual(texts, ["let", "\"ก่า\"", "// é"])
    }
}
