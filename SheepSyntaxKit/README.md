# SheepSyntaxKit

SheepText's syntax highlighter. Pure Swift, no C, no third-party code, no
Foundation in the core. It reads UTF-16 code units and writes runs of
`SyntaxScope`; the app maps a scope to a colour. Its one dependency is
NetworkHighlightKit (ours, shared with SheepTerm) for network configs.

It replaced tree-sitter (the C runtime, swift-tree-sitter, 22 grammar packages
from GitHub, four vendored ones, and the query files) in September 2026.

## Using it

```swift
import SheepSyntaxKit

let session = SyntaxHighlighter(language: .swift)   // one per document
let config  = SyntaxHighlighter(networkVendor: .cisco)  // network_config
let first = session.update(text)                     // changedRanges == nil
let next  = session.update(editedText)               // changedRanges == [range]
for run in next.runs { /* run.location, run.length (UTF-16), run.scope.captureName */ }

SyntaxLanguage(identifier: "tsx")   // .typescript — ids, extensions, fence words
SyntaxHighlighter.runs(for: text, language: .json)  // one-shot
```

`runs` are sorted, non-overlapping, never cross a line break, and cover the
whole text. `changedRanges` says where they can differ from the previous
result once that is shifted across the edit.

## Languages

bash, c (with enough C++/Objective-C for headers), csharp, css, diff,
dockerfile, elixir, go, haskell, html, java, javascript (+JSX), json (+JSONC),
log (SheepText's own log language), markdown, php, python, ruby, rust, scala,
sql, swift, toml, typescript (+TSX), xml, yaml — and **network config** for
every NetworkHighlightKit vendor (Cisco, Aruba CX/OS, Huawei, Comware,
Juniper, PAN-OS, FortiOS, Gaia, Linux, auto), with Cisco's `vlan` and
`spanning-tree mode` validators.

Embedded languages: markdown fences in any of the above (by info string),
HTML `<script>` (JavaScript, TypeScript by `lang`, JSON by `type`) and
`<style>` (CSS), PHP islands in HTML, markdown front matter (YAML/TOML),
Dockerfile `RUN`/`CMD`/`ENTRYPOINT` (Bash), markdown HTML blocks and inline
HTML.

## Design

### One rule: a line's tokens are a function of its incoming state

Every lexer is `lex(ctx, from, to, &state)` over one line. `LexState` is what a
line needs to know about everything above it: a stack of lexer-defined frames
(open block comment and its depth, unterminated multi-line string, template
literal's `${`, JSX nesting, heredoc…), a little text (a heredoc terminator),
and the state of an embedded language (`inner`). Most lines of most files carry
`LexState()`, which allocates nothing.

`finishLine` runs at every line end and drops what cannot survive a line break
(a single-line string left open), so an unterminated literal never leaks.

### Exact incremental passes

`SyntaxHighlighter` keeps the text, where every line starts, the state every
line starts in, and the run list. `update`:

1. finds the edit as the common prefix and suffix of old and new text;
2. backs up to the line holding the unit before the edit (a CR that becomes
   half of a CRLF changes the line above) — and, for markdown, over the lines
   whose lookahead could reach it;
3. re-lexes forward, and after each line past the edit checks whether the
   state entering the next line equals the state the OLD text had there;
4. at the first match, every remaining line is provably unchanged: its runs
   are the old ones shifted by the edit's length delta.

So an incremental result is not an approximation of a clean pass, it IS one.
`IncrementalTests.testIncrementalEqualsCleanForEveryLanguage` fuzzes that for
every sample with edits biased towards the characters that open and close
multi-line constructs, and checks that nothing outside `changedRanges` moved.
`SHEEPSYNTAX_FUZZ=1` runs it 20 seeds deep (≈200,000 edits).

Opening a `/*` recolours to the end of the file (the states never agree
again); typing inside a line recolours that line.

### Lookahead (markdown only)

A markdown line may read up to `lookaheadLines` (24) following lines, never
past a blank line, through `LexContext.forEachFollowingLine` — to see a setext
underline, or the closer of an emphasis it opens. The session's restart rule
uses the same two limits, which is what keeps (2) above exact. Nothing else
reads past its own line; `LexContext.at` returns 0 outside it.

### Scopes

`SyntaxScope.captureName` is the dotted name the host resolves
(`function.method`, `string.escape`, `text.title`, `diff.plus`…), the same
hierarchy tree-sitter captures used, so the app's palette did not change.
There is no `variable`, `operator` or plain `punctuation` scope: in every
palette SheepText ships they are the base foreground.

### Code map

| File | What |
|---|---|
| `SyntaxHighlighter.swift` | session, line table, incremental pass |
| `LexState.swift` / `LexContext.swift` | state, frames, the line a lexer sees, the run sink |
| `WordTable.swift` | keyword lookup without allocating a String per identifier |
| `SyntaxLanguage.swift` | ids, aliases, dispatch |
| `Lexers/CFamilyLexer.swift` + `CFamilySpec.swift` | Swift, JS/TS (+JSX), Go, Rust, Java, C, C#, Scala, PHP code — one machine, per-language data |
| `Lexers/PythonLexer.swift`, `RubyLexer.swift`, `BashLexer.swift` | scripting languages |
| `Lexers/FunctionalLexers.swift` | Elixir, Haskell, Dockerfile |
| `Lexers/DataLexers.swift` | JSON, YAML, TOML |
| `Lexers/MarkupLexer.swift` | HTML, XML, CSS, PHP (HTML + islands) |
| `Lexers/MarkdownLexer.swift` | CommonMark blocks + GFM, inlines |
| `Lexers/TextLexers.swift` | Diff, Log, SQL |
| `Lexers/NetworkConfigLexer.swift` | network config: vendor table, validators, NetworkHighlightKit's scanner |

### Adding a language

1. A `SyntaxLanguage` case, its aliases in `init?(identifier:)`, and a line in
   `lex` / `finishLine`. A brace language is usually just a `CFamilySpec`.
2. A sample in `Tests/SheepSyntaxKitTests/Samples.swift` — that alone puts it
   under the fuzz — and a few assertions in `LanguageTests`.
3. Read the rendering: `SHEEPSYNTAX_DUMP=/tmp/dump.txt swift test --filter DumpTests`.

## Performance

Release, x86-64 Linux, ~1 MB of each sample (`SHEEPSYNTAX_PERF=1 swift test -c
release -Xswiftc -enable-testing --filter PerformanceTests`):

- clean pass: 4–25 ms per language
- keystroke in the middle: 0.6–1.1 ms; newline: 0.6–1.8 ms

For comparison, tree-sitter needed ~520 ms for a clean parse of a
100k-character Swift file; SheepSyntaxKit needs 2.4 ms.

## Testing

Everything here builds and runs on Linux as well as macOS: `swift test`.

- `IncrementalTests` — incremental = clean, from realistic samples, per grammar
  (network config included); `SHEEPSYNTAX_FUZZ=1` for the deep run.
- `GarbageTests` — random units (lone surrogates, NUL, U+2028, very long
  lines) through every grammar: no trap, no hang, still exact.
- `MinifiedTests` (`SHEEPSYNTAX_PERF=1`) — one-line files at 100k and 400k:
  the ratio must stay near 4, i.e. linear, never 16.
- `LanguageTests` — one assertion per behaviour worth keeping.
