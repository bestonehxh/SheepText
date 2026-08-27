<p align="center">
  <img src=".github/icon.png" width="128" alt="SheepText app icon">
</p>

# 🐑 SheepText

**A fast, native macOS text editor — AppKit + SwiftUI, tree-sitter highlighting, and a JavaScript plugin system.**

SheepText is built for people who want a lightweight editor that stays out of the way:
cold start under 300 ms, a small footprint, Sublime-familiar shortcuts — with a few
tricks aimed at network engineers (Cisco IOS and Aruba CX syntax modes, log
highlighting, MAC address format conversion).

## ⬇️ Download

[![Download SheepText for macOS](https://img.shields.io/badge/Download-SheepText_1.3.4_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepText-app/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepText-app/releases/latest)** — download the `.zip`, unzip, and drag **SheepText.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepText.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon.
> The app can check for updates on its own (Settings → General).

## Features

### Editor
- Tabbed editing with per-tab undo history and session restore
- **Multi-cursor**: add next occurrence (⌘D), select all occurrences (⌘⌃⌥D)
- **Code folding** of brace blocks from the gutter — folds are saved per document
- Line numbers, invisible characters, word wrap (per document)
- Auto-save (configurable 1–30 s) plus **backup-while-editing**: a draft copy every
  1.5 s, recoverable via File → Recovered Drafts…
- Large File Mode (highlighting steps aside above a size threshold) and a
  binary-file guard on open
- Correct Thai / grapheme-cluster column handling

### Syntax highlighting (tree-sitter)
- **29 languages**: Swift, JSON, YAML, Markdown, HTML, CSS, JavaScript, TypeScript,
  Python, Go, Rust, Shell, Ruby, Java, C, C#, TOML, XML, Elixir, Scala, Haskell,
  PHP, SQL, Diff, Dockerfile, plain text, **Log**, **Cisco IOS**, and **Aruba CX**
- Smart extension detection (`.cfg`/`.ios` → Cisco IOS, `.cx`/`.aoscx` → Aruba CX,
  `.log`/`.conf` → Log, `Dockerfile` by filename) — remappable at runtime by plugins
- Highlight themes: Adaptive (follows system), One Dark, One Light
- User-overridable `highlights.scm` queries per language

### Find & replace
- Find / Find and Replace in the document (⌘F / ⌘⌥F)
- **Find in Files** (⌘⇧F) across the workspace — case, whole-word, and regex options —
  plus Replace in Files with automatic backups

### Compare mode
- Side-by-side diff of two tabs or a tab and a file
- Line-level and word-level diff, moved-line detection, live update as you type
- Transfer changed blocks between panes (line endings re-terminated correctly)

### Text tools (Tools menu / command palette)
Go to Line, Duplicate/Delete Line, Uppercase/Lowercase/Title Case, Sort Lines,
Remove Duplicate Lines, Trim Trailing Spaces, **Convert MAC Address Format**,
Convert Line Endings (LF/CRLF), Convert Indentation (2/4 spaces or tabs)

### Workspace
- Open a folder as workspace: file tree, create/rename/delete, recent folders
- **Command palette** (⌘⇧P) with fuzzy search over every command — plugins included
- Automatic encoding detection (UTF-8/UTF-16/Latin-1/Windows-1252 …), BOM and
  line-ending preservation

### Plugin system
JavaScript plugins (JavaScriptCore, sandboxed per plugin) loaded from
`~/Library/Application Support/SheepText/Plugins/`. A plugin is a folder with a
`plugin.json` manifest and a `src/index.js`:

```json
{
  "id": "hello-world",
  "name": "Hello World",
  "version": "1.0.0",
  "main": "src/index.js",
  "contributes": {
    "commands": [{ "id": "hello.reverseLine", "title": "Reverse Current Line" }],
    "keybindings": [{ "command": "hello.reverseLine", "key": "cmd+alt+r" }]
  }
}
```

Available bridges: `commands` (register/execute), `editor` (text, selection, current
line, language, extension→language remapping), `fs` (scoped to the workspace and the
plugin folder), `workspace` (root path, glob file search), `ui` (notifications,
status messages), and `console` logging. Two example plugins ship in
[`Plugins/`](Plugins/).

## Requirements

- macOS 26.4 (Tahoe) or later, Apple Silicon

## Building

```bash
xcodebuild -project SheepText.xcodeproj -scheme SheepText -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

Swift package dependencies (tree-sitter grammars) resolve automatically. Run the
tests with:

```bash
xcodebuild test -project SheepText.xcodeproj -scheme SheepText \
  -destination 'platform=macOS,arch=arm64'
```

## The Sheep family 🐑

SheepText is one of four small native macOS apps that share the same sheep icon set:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm-app/main/.github/icon.png" width="44" alt=""> | [SheepTerm](https://github.com/bestonehxh/SheepTerm-app) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap-app/main/.github/icon.png" width="44" alt=""> | [SheepTap](https://github.com/bestonehxh/SheepTap-app) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing-app/main/.github/icon.png" width="44" alt=""> | [SheepPing](https://github.com/bestonehxh/SheepPing-app) | Continuous multi-host ping monitor with per-host logs and CSV export |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText-app/main/.github/icon.png" width="44" alt=""> | [SheepText](https://github.com/bestonehxh/SheepText-app) | Fast text editor with tree-sitter highlighting and a JavaScript plugin system |

## Acknowledgements

- [swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter) and the
  [tree-sitter](https://tree-sitter.github.io) ecosystem — grammars for each language
  are pulled via Swift Package Manager; see each grammar's repository for its license
- Vendored grammars (all MIT): [tree-sitter-diff](TreeSitterDiffVendored/LICENSE)
  (Michael Davis), [tree-sitter-sql](TreeSitterSqlVendored/LICENSE) (Derek Stride),
  [tree-sitter-yaml](TreeSitterYAMLVendored/LICENSE) (tree-sitter-grammars / Ika)

## License

[MIT](LICENSE) © 2026 bestonehxh
