import NetworkHighlightKit

/// Every language SheepSyntaxKit can highlight.
///
/// `network_config` is not here: it is SheepText's own line-local highlighter
/// over NetworkHighlightKit and lives in the app.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case bash
    case c
    case csharp
    case css
    case diff
    case dockerfile
    case elixir
    case go
    case haskell
    case html
    case java
    case javascript
    case json
    case log
    case markdown
    case php
    case python
    case ruby
    case rust
    case scala
    case sql
    case swift
    case toml
    case typescript
    case xml
    case yaml

    /// Resolves a document language id, a file extension or a markdown fence's
    /// info word. Case-insensitive; nil for anything unknown.
    public init?(identifier: String) {
        let key = identifier.lowercased()
        if let direct = SyntaxLanguage(rawValue: key) {
            self = direct
            return
        }
        switch key {
        case "sh", "shell", "zsh", "fish", "ksh", "console", "shellsession", "bash_log": self = .bash
        case "h", "cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c", "objectivec", "m", "mm": self = .c
        case "c#", "cs": self = .csharp
        case "scss", "less": self = .css
        case "patch", "udiff": self = .diff
        case "docker", "containerfile": self = .dockerfile
        case "ex", "exs", "heex": self = .elixir
        case "golang": self = .go
        case "hs", "lhs": self = .haskell
        case "htm", "xhtml", "vue", "svelte": self = .html
        case "js", "jsx", "mjs", "cjs", "node": self = .javascript
        case "jsonc", "json5", "jsonl", "geojson": self = .json
        case "besttext_log", "logs": self = .log
        case "md", "mdx", "markdown_inline", "gfm": self = .markdown
        case "py", "python3", "py3", "pyw", "gyp": self = .python
        case "rb", "gemspec", "rake", "podspec": self = .ruby
        case "rs": self = .rust
        case "sc", "sbt": self = .scala
        case "psql", "mysql", "sqlite", "pgsql", "plsql", "tsql": self = .sql
        case "ts", "tsx", "mts", "cts": self = .typescript
        case "svg", "plist", "xsd", "xsl", "xslt", "rss", "atom", "storyboard", "xib": self = .xml
        case "yml": self = .yaml
        default: return nil
        }
    }

    /// How many following lines a line's tokens may depend on. Markdown
    /// reads ahead inside its own paragraph — a setext underline, the closer
    /// of an emphasis opened on this line — and never past a blank line.
    /// Nothing else reads past its own line.
    var lookaheadLines: Int { self == .markdown ? 24 : 0 }

    /// Language-specific JSX: `<div>` in an expression position is markup.
    var allowsJSX: Bool { self == .javascript || self == .typescript }

    func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        switch self {
        case .bash: BashLexer.lex(&ctx, from, to, &state)
        case .c, .csharp, .go, .java, .javascript, .rust, .scala, .swift, .typescript:
            CFamilyLexer.lex(CFamilySpec.spec(for: self), &ctx, from, to, &state)
        case .css: CSSLexer.lex(&ctx, from, to, &state)
        case .diff: DiffLexer.lex(&ctx, from, to, &state)
        case .dockerfile: DockerfileLexer.lex(&ctx, from, to, &state)
        case .elixir: ElixirLexer.lex(&ctx, from, to, &state)
        case .haskell: HaskellLexer.lex(&ctx, from, to, &state)
        case .html: MarkupLexer.lex(.html, &ctx, from, to, &state)
        case .xml: MarkupLexer.lex(.xml, &ctx, from, to, &state)
        case .json: JSONLexer.lex(&ctx, from, to, &state)
        case .log: LogLexer.lex(&ctx, from, to, &state)
        case .markdown: MarkdownLexer.lex(&ctx, from, to, &state)
        case .php: PHPLexer.lex(&ctx, from, to, &state)
        case .python: PythonLexer.lex(&ctx, from, to, &state)
        case .ruby: RubyLexer.lex(&ctx, from, to, &state)
        case .sql: SQLLexer.lex(&ctx, from, to, &state)
        case .toml: TOMLLexer.lex(&ctx, from, to, &state)
        case .yaml: YAMLLexer.lex(&ctx, from, to, &state)
        }
    }

    /// Called once at the end of every line with the state that line leaves.
    /// Drops whatever cannot survive a line break (a single-line string left
    /// open, say), so an unterminated literal does not leak into the next line.
    func finishLine(_ state: inout LexState) {
        switch self {
        case .c, .csharp, .go, .java, .javascript, .rust, .scala, .swift, .typescript:
            CFamilyLexer.finishLine(CFamilySpec.spec(for: self), &state)
        case .php: PHPLexer.finishLine(&state)
        case .html: MarkupLexer.finishLine(.html, &state)
        case .markdown: MarkdownLexer.finishLine(&state)
        case .dockerfile: DockerfileLexer.finishLine(&state)
        case .ruby: RubyLexer.finishLine(&state)
        case .bash: BashLexer.finishLine(&state)
        default: break
        }
    }
}

/// What one session highlights: a language, or network config for one
/// device family. The vendor is part of the grammar, so a vendor change is a
/// new session and never a stale run list.
public enum SyntaxGrammar: Hashable, Sendable {
    case language(SyntaxLanguage)
    case networkConfig(Vendor)

    var lookaheadLines: Int {
        if case .language(let language) = self { return language.lookaheadLines }
        return 0
    }

    func lex(_ ctx: inout LexContext, _ from: Int, _ to: Int, _ state: inout LexState) {
        switch self {
        case .language(let language): language.lex(&ctx, from, to, &state)
        case .networkConfig(let vendor): NetworkConfigHighlighter.lex(vendor, &ctx, from, to)
        }
    }

    func finishLine(_ state: inout LexState) {
        if case .language(let language) = self { language.finishLine(&state) }
    }
}
