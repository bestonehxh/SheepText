import XCTest
@testable import SheepSyntaxKit

/// Timings for the numbers quoted in README.md. Printed, not asserted: CI
/// machines vary. `swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`.
final class PerformanceTests: XCTestCase {
    private func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testLargeDocuments() throws {
        guard ProcessInfo.processInfo.environment["SHEEPSYNTAX_PERF"] != nil else { throw XCTSkip("set SHEEPSYNTAX_PERF") }
        for (language, sample) in Samples.grammars {
            // ~1 MB of each language.
            let copies = max(1, 1_000_000 / sample.utf16.count)
            let text = Array(String(repeating: sample + "\n", count: copies).utf16)
            let session = SyntaxHighlighter(grammar: language)
            var runs = 0
            let full = time { runs = session.update(text).runs.count }

            // One keystroke in the middle, then a newline, then undo.
            var edited = text
            let middle = text.count / 2
            edited.insert(0x78, at: middle)
            let keystroke = time { _ = session.update(edited) }
            edited.insert(0x0A, at: middle + 1)
            let newline = time { _ = session.update(edited) }
            let undo = time { _ = session.update(text) }
            print(String(format: "PERF %-11@ %7d units %6d runs  full %7.2f ms  key %6.3f ms  newline %6.3f ms  undo %6.3f ms",
                         "\(language)" as NSString, text.count, runs, full, keystroke, newline, undo))
        }
    }
}

/// Minified files are one enormous line. Anything that rescans the rest of the
/// line per token is quadratic there, and this is where it would show.
final class MinifiedTests: XCTestCase {
    private let units: [(SyntaxLanguage, String)] = [
        (.javascript, "var a=b<c?d/e:f;function g(h){return h.map(x=>x*2).filter(y=>y<3)}if(a<b&&c>d){e=[1,2,3];t=`x${a}y`}r=/ab+c/g.test(s);"),
        (.typescript, "const f=<T,>(x:T):T=>x;let a:Array<number>=g<string>(q);if(a<b){c=d as Foo<Bar>};"),
        (.css, ".a{color:red;margin:0 auto}#b:hover>c{width:calc(100% - 2px)}@media(max-width:600px){d{e:f}}"),
        (.json, "{\"k\":\"v\",\"n\":-1.5e3,\"a\":[1,2,{\"b\":null,\"c\":true}]},"),
        (.html, "<div class=\"a\"><p>x &amp; y</p><img src=\"a.png\"/><script>if(a<b){c()}</script><style>a{b:c}</style></div>"),
        (.xml, "<a x=\"1\"><b>t&amp;u</b><c/><![CDATA[a<b]]><!-- c --></a>"),
        (.markdown, "a *b* **c** `d` [e](f) <g> h_i_ ![j](k) <https://l> m\\* *n "),
        (.sql, "SELECT a,b FROM t WHERE c<d AND e='f''g' ORDER BY h;"),
        (.yaml, "{a: 1, b: [x, y, \"z\"], c: {d: e}}, "),
        (.swift, "let a=b<c ? f<Int>(x) : g(y);if a<b{c=[1,2].map{$0<3}};"),
        (.csharp, "var a=b<c?F<int>(x):G(y);if(a<b){c=new List<int>{1,2};}"),
        (.php, "<?php $a=$b<$c?f($x):g(\"$y {$z->w}\");?><b>x</b>"),
    ]

    func testOneLineFilesStayLinear() throws {
        guard ProcessInfo.processInfo.environment["SHEEPSYNTAX_PERF"] != nil else { throw XCTSkip("set SHEEPSYNTAX_PERF") }
        for (language, unit) in units {
            var times: [Double] = []
            for size in [100_000, 400_000] {
                let text = String(repeating: unit, count: size / unit.utf16.count)
                let start = DispatchTime.now().uptimeNanoseconds
                _ = SyntaxHighlighter(language: language).update(text)
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            // Linear means 4x the text costs ~4x the time; quadratic would be ~16x.
            print(String(format: "MINIFIED %-10@ 100k %7.1f ms  400k %7.1f ms  ratio %.1f",
                         language.rawValue as NSString, times[0], times[1], times[1] / times[0]))
        }
    }
}
