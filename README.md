<p align="center">
  <img src=".github/icon.png?v=3" width="128" alt="SheepText app icon">
</p>

# 🐑 SheepText

**A fast, native macOS text editor — AppKit + SwiftUI, with its own pure-Swift syntax highlighter.**

SheepText is built for people who want a lightweight editor that stays out of the way:
cold start under 300 ms, a small footprint, Sublime-familiar shortcuts — with a few
tricks aimed at network engineers (device-config highlighting for ten vendor
families in the same colours as SheepTerm, log highlighting, MAC address format
conversion).

## ⬇️ Download

[![Download SheepText for macOS](https://img.shields.io/badge/Download-SheepText_4.1_for_macOS-2ea44f?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/bestonehxh/SheepText/releases/latest)

**[Get the latest release →](https://github.com/bestonehxh/SheepText/releases/latest)** — download the `.zip`, unzip, and drag **SheepText.app** into `Applications`.

> The build is unsigned (not notarized), so macOS will warn on first launch —
> right-click the app and choose **Open**, or run
> `xattr -dr com.apple.quarantine /Applications/SheepText.app`
>
> Requires macOS 26.4 (Tahoe) or later, Apple Silicon.
> After that, SheepText updates itself: it checks for new releases automatically and
> installs them with one click (Settings → Updates → Check Now to check right away).

## The Sheep family 🐑

SheepText is one of a few small native macOS apps for network engineers:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTerm/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTerm"> | **[SheepTerm](https://github.com/bestonehxh/SheepTerm)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTerm/releases/latest) | SSH / Serial / local-shell terminal for network engineers |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepText/main/.github/icon.png?v=3" width="48" height="48" alt="SheepText"> | **[SheepText](https://github.com/bestonehxh/SheepText)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepText/releases/latest) | Fast native text editor with network-config highlighting and side-by-side compare |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepDrop/main/.github/icon.png?v=3" width="48" height="48" alt="SheepDrop"> | **[SheepDrop](https://github.com/bestonehxh/SheepDrop)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepDrop/releases/latest) | SFTP / SCP / FTP / TFTP file transfer — client and built-in server |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepTap/main/.github/icon.png?v=3" width="48" height="48" alt="SheepTap"> | **[SheepTap](https://github.com/bestonehxh/SheepTap)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepTap/releases/latest) | Menu-bar viewer for your Mac's network interfaces with click-to-copy |
| <img src="https://raw.githubusercontent.com/bestonehxh/SheepPing/main/.github/icon.png?v=3" width="48" height="48" alt="SheepPing"> | **[SheepPing](https://github.com/bestonehxh/SheepPing)**<br>[⬇️ Download](https://github.com/bestonehxh/SheepPing/releases/latest) | Continuous multi-host ping monitor with per-host logs and CSV export |

## The Lab family 🧪

The servers and hypervisor control a network lab needs, native on the Mac:

|  | App | What it does |
|---|---|---|
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDC/main/.github/icon.png?v=2" width="48" height="48" alt="LabDC"> | **[LabDC](https://github.com/bestonehxh/LabDC)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDC/releases/latest) | Active Directory–compatible domain controller with RADIUS for 802.1X and a lab CA |
| <img src="https://raw.githubusercontent.com/bestonehxh/LabDock/main/.github/icon.png?v=1" width="48" height="48" alt="LabDock"> | **[LabDock](https://github.com/bestonehxh/LabDock)**<br>[⬇️ Download](https://github.com/bestonehxh/LabDock/releases/latest) | VM control and console for standalone ESXi hosts — power, snapshots, guest files and scripts, no vCenter |

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

### Syntax highlighting
- Its own highlighter, written in pure Swift (no tree-sitter, no C): a full pass over a
  1 MB file takes milliseconds and a keystroke re-colours only the lines it affects
- **28 languages**: Swift, JSON, YAML, Markdown, HTML, CSS, JavaScript, TypeScript,
  Python, Go, Rust, Shell, Ruby, Java, C / C++ / Objective-C, C#, TOML, XML, Elixir,
  Scala, Haskell, PHP, SQL, Diff, Dockerfile, plain text, **Log**, and **Network config**
- **Network config**: one mode for Cisco, Aruba CX, ArubaOS, Huawei, H3C Comware,
  Juniper, Palo Alto PAN-OS, FortiOS, Check Point Gaia and Linux. The vendor is
  detected from the content (or picked from the status bar), and the colours match
  SheepTerm: interfaces orange, VLANs yellow, addresses cyan, masks purple, MACs pink,
  up / warning / down states in bold green, amber and red. Cisco VLAN lists and
  spanning-tree modes are checked — a typo like `vlan 306s` shows in red
- Smart extension detection (`.cfg` `.ios` `.cisco` `.conf` `.txt` → Network config,
  `.cx` `.aoscx` → Aruba CX, `.log` → Log, `Dockerfile` by filename)
- Highlight themes: Adaptive (follows system), One Dark, One Light

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
- **Command palette** (⌘⇧P) with fuzzy search over every command
- Automatic encoding detection (UTF-8/UTF-16/Latin-1/Windows-1252 …), BOM and
  line-ending preservation

## Requirements

- macOS 26.4 (Tahoe) or later, Apple Silicon

## Building

```bash
xcodebuild -project SheepText.xcodeproj -scheme SheepText -configuration Release \
  -destination 'platform=macOS,arch=arm64' build
```

There are no remote dependencies: the highlighter (`SheepSyntaxKit`) and the
network-config scanner (`NetworkHighlightKit`) are local Swift packages in this repo.
Run the tests with:

```bash
xcodebuild test -project SheepText.xcodeproj -scheme SheepText \
  -destination 'platform=macOS,arch=arm64'
```

## License

[MIT](LICENSE) © 2026 bestonehxh
