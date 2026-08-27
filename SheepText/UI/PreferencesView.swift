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
        }
        .frame(width: 520)
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

            Section("Sidebar") {
                Picker("Sidebar style", selection: $preferences.sidebarStyle) {
                    ForEach(SidebarStyle.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
            }

            Section("Layout") {
                Toggle("Show sidebar on launch", isOn: $preferences.showSidebarByDefault)
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
/// "Native Clean" palette in AppColors.swift but cannot use it directly: the
/// preview must always show its own mode, not follow the window's appearance.
private struct ThemePreviewPalette {
    let chrome: Color
    let sidebar: Color
    let editor: Color
    let line: Color
    let accent: Color

    static let light = ThemePreviewPalette(
        chrome:  Color(hexRGB: 0xD9E0E8),
        sidebar: Color(hexRGB: 0xE9EEF4),
        editor:  Color(hexRGB: 0xFBFCFE),
        line:    Color(hexRGB: 0xC5CFDA),
        accent:  Color(hexRGB: 0x2874C6)
    )
    static let dark = ThemePreviewPalette(
        chrome:  Color(hexRGB: 0x21252B),
        sidebar: Color(hexRGB: 0x252A31),
        editor:  Color(hexRGB: 0x282C34),
        line:    Color(hexRGB: 0x4A5160),
        accent:  Color(hexRGB: 0x61AFEF)
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
