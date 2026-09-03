//
//  PreferencesView.swift
//  App preferences shown from SheepText > Settings.
//
//  Uses SwiftUI TabView so macOS renders the native icon-toolbar at the top
//  (same pattern as Xcode, BBEdit). Each pane is loaded on first selection
//  only, which makes the window open instantly.
//

import AppKit
import SwiftUI

struct PreferencesView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General",    systemImage: "gearshape") }
            EditorSettingsPane()
                .tabItem { Label("Editor",     systemImage: "text.cursor") }
            AppearanceSettingsPane()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            SyntaxSettingsPane()
                .tabItem { Label("Syntax",     systemImage: "curlybraces") }
            KeybindingsSettingsPane()
                .tabItem { Label("Keys",       systemImage: "keyboard") }
            // The plugin subsystem's only entry point. PluginsView existed but
            // nothing ever showed it, so a user had no way to see what had
            // loaded, install one, or reload after editing.
            PluginsView()
                .tabItem { Label("Plugins",    systemImage: "puzzlepiece.extension") }
        }
        // Height matters as much as width here: with only a width set, the
        // window sized itself so the Appearance pane was cut off just below
        // Chrome — and a macOS Form gives no visible hint that it scrolls, so
        // everything past the fold read as simply not existing. 540 is what it
        // takes for Appearance, the tallest pane that can fit, to show whole.
        //
        // General cannot be made to fit and is not meant to: it carries five
        // sections. That is exactly why "Show sidebar on launch" belongs at the
        // TOP of it rather than below the fold of another pane — no window size
        // fixes a control nobody scrolls to.
        .frame(width: 520)
        .frame(minHeight: 540)
        .background(Color(nsColor: .bestTextPanelBackground))
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("On Launch") {
                Picker("Behavior", selection: $preferences.launchBehavior) {
                    ForEach(LaunchBehavior.allCases) { b in
                        Text(b.displayName).tag(b)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // Lived under Appearance → Layout, which is where nobody looked:
                // this IS launch behaviour, and it sat below the fold of a pane
                // that gave no sign it scrolled.
                Toggle("Show sidebar on launch", isOn: $preferences.showSidebarByDefault)
            }

            Section("New Document") {
                Picker("Syntax", selection: $preferences.defaultLanguage) {
                    ForEach(LanguageDetector.supportedLanguages) { l in
                        Text(l.displayName).tag(l.id)
                    }
                }
                Picker("Encoding", selection: $preferences.defaultEncoding) {
                    ForEach(TextEncoding.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                Picker("Line endings", selection: $preferences.defaultLineEnding) {
                    ForEach(TextLineEnding.allCases) { le in
                        Text(le.displayName).tag(le)
                    }
                }
            }

            Section("Saving") {
                Toggle("Auto save", isOn: $preferences.autoSaveEnabled)
                LabeledContent("Delay") {
                    Slider(value: $preferences.autoSaveDelay, in: 1...30, step: 1)
                        .disabled(!preferences.autoSaveEnabled)
                        .frame(width: 140)
                    Text("\(Int(preferences.autoSaveDelay))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
                Toggle("Backup while editing",        isOn: $preferences.backupDocumentsWhileEditing)
                Toggle("Confirm before closing unsaved", isOn: $preferences.askBeforeClosingUnsavedDocuments)
            }

            Section("File Opening") {
                Toggle("Auto-detect encoding",        isOn: $preferences.detectsEncodingAutomatically)
                Toggle("Detect syntax by extension",  isOn: $preferences.detectsSyntaxByFileExtension)
                Toggle("Warn when opening large files", isOn: $preferences.warnsWhenOpeningLargeFiles)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $preferences.checksForUpdatesAutomatically)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editor

private struct EditorSettingsPane: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Font") {
                Picker("Name", selection: $preferences.editorFontName) {
                    ForEach(AppPreferences.availableEditorFontNames, id: \.self) { name in
                        Text(AppPreferences.displayName(forEditorFontName: name)).tag(name)
                    }
                }
                LabeledContent("Size") {
                    Slider(value: $preferences.editorFontSize, in: 9...36, step: 1)
                        .frame(width: 140)
                    Text("\(Int(preferences.editorFontSize)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Editing") {
                Picker("Tab size", selection: $preferences.defaultIndentation) {
                    ForEach(TextIndentation.allCases) { i in
                        Text(i.displayName).tag(i)
                    }
                }
                Toggle("Word wrap",            isOn: $preferences.wordWrapByDefault)
                Toggle("Line numbers",         isOn: $preferences.showsLineNumbers)
                Toggle("Invisible characters", isOn: $preferences.showsInvisibleCharactersByDefault)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPane: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Theme") {
                HStack(spacing: 14) {
                    ForEach(AppThemeMode.allCases) { mode in
                        ThemeModeCard(mode: mode,
                                      isSelected: preferences.themeMode == mode) {
                            preferences.themeMode = mode
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                Text("Changes the whole app immediately. System Default follows the Mac's appearance.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Chrome") {
                Picker("Style", selection: $preferences.chromeStyle) {
                    ForEach(ChromeStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text("How the tab bar and sidebar are painted. Liquid Glass picks up the desktop behind the window; Solid Color keeps the flat chrome tile. The layout is the same either way — the editor itself is never translucent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Editor Text Color") {
                ColorPicker("Light mode", selection: colorBinding(\.editorLightTextColor))
                ColorPicker("Dark mode",  selection: colorBinding(\.editorDarkTextColor))
                Button("Reset to defaults") { preferences.resetEditorAppearance() }
                    .foregroundStyle(Color(nsColor: .bestTextDanger))
            }
        }
        .formStyle(.grouped)
    }

    private func colorBinding(_ kp: ReferenceWritableKeyPath<AppPreferences, NSColor>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: preferences[keyPath: kp]) },
            set: { preferences[keyPath: kp] = NSColor($0) }
        )
    }
}

// MARK: - Theme mode cards

/// Fixed colours for the mini-window previews. These deliberately mirror the
/// Graphite & Signal palette in AppColors.swift but cannot use it directly:
/// the preview must always show its own mode, not follow the window's
/// appearance — and that includes the accent. It used to read
/// `controlAccentColor`, which made the card preview a colour the app never
/// paints: a user with a purple system accent saw purple cards and a blue
/// app. These are the same two values as `bestTextAccent` in AppColors.swift
/// and must be changed together with it.
/// `internal`, not `private`: AppColorsTests asserts these accent values
/// against `NSColor.bestTextAccent` so the two cannot drift apart again.
struct ThemePreviewPalette {
    let chrome: Color
    let sidebar: Color
    let editor: Color
    let line: Color
    let accent: Color

    /// Raw hex, kept as constants so a test can compare them with the app's
    /// own colours instead of re-typing the literals a third time.
    static let lightAccentHex: UInt32 = 0x0A72D6
    static let darkAccentHex:  UInt32 = 0x4FA3F7
    static let lightChromeHex: UInt32 = 0xEEEEEF
    static let lightSidebarHex: UInt32 = 0xE9E9EB
    static let lightEditorHex: UInt32 = 0xFCFCFD
    static let darkChromeHex:  UInt32 = 0x1A1B1D
    static let darkSidebarHex: UInt32 = 0x161719
    static let darkEditorHex:  UInt32 = 0x1A1B1E

    static let light = ThemePreviewPalette(
        chrome:  Color(hexRGB: lightChromeHex),
        sidebar: Color(hexRGB: lightSidebarHex),
        editor:  Color(hexRGB: lightEditorHex),
        line:    Color(hexRGB: 0xD7D7DA),
        accent:  Color(hexRGB: lightAccentHex)
    )
    static let dark = ThemePreviewPalette(
        chrome:  Color(hexRGB: darkChromeHex),
        sidebar: Color(hexRGB: darkSidebarHex),
        editor:  Color(hexRGB: darkEditorHex),
        line:    Color(hexRGB: 0x2E2F33),
        accent:  Color(hexRGB: darkAccentHex)
    )
}

private extension Color {
    init(hexRGB hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Same selectable-thumbnail pattern as SheepTerm's app-icon picker:
/// rounded thumbnail, 3 pt accent stroke when selected, small label below.
private struct ThemeModeCard: View {
    let mode: AppThemeMode
    let isSelected: Bool
    let action: () -> Void

    private var shortName: String {
        switch mode {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                preview
                    .frame(width: 88, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color(nsColor: .bestTextAccent) : Color.clear,
                                    lineWidth: 3)
                    )
                Text(shortName)
                    .font(.system(size: 10, weight: isSelected ? .bold : .regular))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        switch mode {
        case .light:
            miniWindow(.light)
        case .dark:
            miniWindow(.dark)
        case .system:
            // Light on the left, dark on the right, split on a diagonal.
            ZStack {
                miniWindow(.light)
                miniWindow(.dark)
                    .clipShape(DiagonalHalf())
            }
        }
    }

    private func miniWindow(_ p: ThemePreviewPalette) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2.5) {
                ForEach(0..<3) { _ in
                    Circle()
                        .fill(p.line)
                        .frame(width: 3.5, height: 3.5)
                }
                Spacer()
            }
            .padding(.horizontal, 5)
            .frame(height: 11)
            .background(p.chrome)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3.5) {
                    ForEach(0..<3) { i in
                        Capsule()
                            .fill(p.line.opacity(0.8))
                            .frame(width: i == 0 ? 12 : 9, height: 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(5)
                .frame(width: 22, alignment: .leading)
                .background(p.sidebar)

                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(p.accent.opacity(0.85)).frame(width: 24, height: 2)
                    Capsule().fill(p.line).frame(width: 42, height: 2)
                    Capsule().fill(p.line).frame(width: 32, height: 2)
                    Capsule().fill(p.line.opacity(0.7)).frame(width: 37, height: 2)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.editor)
            }
        }
    }
}

/// The right-of-diagonal half of the bounds, used to composite the
/// half-light / half-dark "System" preview.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.62, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Syntax

private struct SyntaxSettingsPane: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Highlight Theme") {
                Picker("Theme", selection: $preferences.highlightTheme) {
                    ForEach(HighlightTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
            }

            Section("Supported Languages") {
                ForEach(LanguageDetector.supportedLanguages) { language in
                    LabeledContent(language.displayName) {
                        Text(language.id)
                            .foregroundStyle(.secondary)
                            .monospaced()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Keybindings

private struct KeybindingsSettingsPane: View {
    var body: some View {
        Form {
            Section("Shortcuts") {
                row("Command Palette",   "⌘⇧P")
                row("Find",              "⌘F")
                row("Find in Files",     "⌘⇧F")
                row("Toggle Sidebar",    "⌘0")
                row("Go to Line",        "⌘L")
                row("Duplicate Line",    "⇧⌘D")
                row("Delete Line",       "⇧⌘K")
                row("Add Next Match",    "⌘D")
                row("Add All Matches",   "⌘⌥⌃G")
                row("Uppercase",         "⇧⌘U")
                row("Lowercase",         "⌥⌘U")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ command: String, _ shortcut: String) -> some View {
        LabeledContent(command) {
            Text(shortcut)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .bestTextHoverBackground),
                            in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
