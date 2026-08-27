//
//  AppPreferences.swift
//  User-facing app preferences persisted in UserDefaults.
//

import AppKit
import SwiftUI
import Observation

enum AppThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System Default"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum LaunchBehavior: String, CaseIterable, Identifiable {
    case newBlankDocument
    case reopenLastSession
    case showOpenPanel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newBlankDocument: return "Open new blank document"
        case .reopenLastSession: return "Reopen documents from last session"
        case .showOpenPanel: return "Show open panel"
        }
    }
}

enum SidebarStyle: String, CaseIterable, Identifiable {
    case automatic
    case compact
    case spacious

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .compact: return "Compact"
        case .spacious: return "Spacious"
        }
    }
}

enum HighlightTheme: String, CaseIterable, Identifiable {
    case adaptive
    case oneDark
    case oneLight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .oneDark: return "One Dark"
        case .oneLight: return "One Light"
        }
    }
}

@Observable
@MainActor
final class AppPreferences {
    static var current: AppPreferences?
    static let systemEditorFontName = "__sheeptext.systemMonospace"

    private let launchBehaviorKey = "sheeptext.general.launchBehavior"
    private let defaultLanguageKey = "sheeptext.document.defaultLanguage"
    private let defaultEncodingKey = "sheeptext.document.defaultEncoding"
    private let defaultLineEndingKey = "sheeptext.document.defaultLineEnding"
    private let backupDocumentsWhileEditingKey = "sheeptext.save.backupDocumentsWhileEditing"
    private let askBeforeClosingUnsavedDocumentsKey = "sheeptext.save.askBeforeClosingUnsavedDocuments"
    private let detectsEncodingAutomaticallyKey = "sheeptext.open.detectEncodingAutomatically"
    private let detectsSyntaxByFileExtensionKey = "sheeptext.open.detectSyntaxByFileExtension"
    private let warnsWhenOpeningLargeFilesKey = "sheeptext.open.warnsWhenOpeningLargeFiles"
    private let checksForUpdatesAutomaticallyKey = "sheeptext.updates.checksAutomatically"
    private let themeModeKey = "sheeptext.themeMode"
    private let editorFontNameKey = "sheeptext.editor.fontName"
    private let editorFontSizeKey = "sheeptext.editor.fontSize"
    private let defaultIndentationKey = "sheeptext.editor.defaultIndentation"
    private let wordWrapByDefaultKey = "sheeptext.editor.wordWrapByDefault"
    private let showsLineNumbersKey = "sheeptext.editor.showsLineNumbers"
    private let showsInvisibleCharactersByDefaultKey = "sheeptext.editor.showsInvisibleCharactersByDefault"
    private let editorLightTextColorKey = "sheeptext.editor.lightTextColor"
    private let editorDarkTextColorKey = "sheeptext.editor.darkTextColor"
    private let autoSaveEnabledKey = "sheeptext.save.autoSaveEnabled"
    private let autoSaveDelayKey = "sheeptext.save.autoSaveDelay"
    private let sidebarStyleKey = "sheeptext.appearance.sidebarStyle"
    private let highlightThemeKey = "sheeptext.syntax.highlightTheme"
    private let showSidebarByDefaultKey = "sheeptext.appearance.showSidebarByDefault"

    var launchBehavior: LaunchBehavior {
        didSet { UserDefaults.standard.set(launchBehavior.rawValue, forKey: launchBehaviorKey) }
    }

    var defaultLanguage: String {
        didSet { UserDefaults.standard.set(defaultLanguage, forKey: defaultLanguageKey) }
    }

    var defaultEncoding: TextEncoding {
        didSet { UserDefaults.standard.set(defaultEncoding.rawValue, forKey: defaultEncodingKey) }
    }

    var defaultLineEnding: TextLineEnding {
        didSet { UserDefaults.standard.set(defaultLineEnding.rawValue, forKey: defaultLineEndingKey) }
    }

    var themeMode: AppThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: themeModeKey)
            // Notification posted from SheepTextApp.applyTheme() *after* NSApp.appearance
            // is set, so effectiveAppearance is correct when observers re-highlight.
        }
    }

    var editorFontName: String {
        didSet {
            cachedEditorFont = nil
            UserDefaults.standard.set(editorFontName, forKey: editorFontNameKey)
            notifyEditorAppearanceChanged()
        }
    }

    var editorFontSize: Double {
        didSet {
            cachedEditorFont = nil
            UserDefaults.standard.set(editorFontSize, forKey: editorFontSizeKey)
            notifyEditorAppearanceChanged()
        }
    }

    /// Memoised result of `editorFont()`.
    ///
    /// `DiffLayoutManager.fixedLineMetrics` asks the owning text view for its font
    /// once per line fragment, on every layout pass, and that walks back to here —
    /// so a plain `NSFont(name:size:)` lookup ran thousands of times to lay out one
    /// screenful. Invalidated by the two properties it depends on.
    ///
    /// @ObservationIgnored so filling the cache during layout does not register a
    /// SwiftUI dependency or mark the model dirty.
    @ObservationIgnored private var cachedEditorFont: NSFont?

    var defaultIndentation: TextIndentation {
        didSet {
            UserDefaults.standard.set(defaultIndentation.rawValue, forKey: defaultIndentationKey)
            notifyEditorAppearanceChanged()
        }
    }

    var wordWrapByDefault: Bool {
        didSet {
            UserDefaults.standard.set(wordWrapByDefault, forKey: wordWrapByDefaultKey)
            notifyEditorAppearanceChanged()
        }
    }

    var showsLineNumbers: Bool {
        didSet {
            UserDefaults.standard.set(showsLineNumbers, forKey: showsLineNumbersKey)
            notifyEditorAppearanceChanged()
        }
    }

    var showsInvisibleCharactersByDefault: Bool {
        didSet {
            UserDefaults.standard.set(showsInvisibleCharactersByDefault, forKey: showsInvisibleCharactersByDefaultKey)
            notifyEditorAppearanceChanged()
        }
    }

    var editorLightTextColor: NSColor {
        didSet {
            UserDefaults.standard.set(Self.hexString(from: editorLightTextColor), forKey: editorLightTextColorKey)
            notifyEditorAppearanceChanged()
        }
    }

    var editorDarkTextColor: NSColor {
        didSet {
            UserDefaults.standard.set(Self.hexString(from: editorDarkTextColor), forKey: editorDarkTextColorKey)
            notifyEditorAppearanceChanged()
        }
    }

    var autoSaveEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSaveEnabled, forKey: autoSaveEnabledKey)
        }
    }

    var backupDocumentsWhileEditing: Bool {
        didSet { UserDefaults.standard.set(backupDocumentsWhileEditing, forKey: backupDocumentsWhileEditingKey) }
    }

    var askBeforeClosingUnsavedDocuments: Bool {
        didSet { UserDefaults.standard.set(askBeforeClosingUnsavedDocuments, forKey: askBeforeClosingUnsavedDocumentsKey) }
    }

    var autoSaveDelay: Double {
        didSet {
            let clamped = max(1, min(30, autoSaveDelay))
            if clamped != autoSaveDelay {
                autoSaveDelay = clamped
                return
            }
            UserDefaults.standard.set(autoSaveDelay, forKey: autoSaveDelayKey)
        }
    }

    var detectsEncodingAutomatically: Bool {
        didSet { UserDefaults.standard.set(detectsEncodingAutomatically, forKey: detectsEncodingAutomaticallyKey) }
    }

    var detectsSyntaxByFileExtension: Bool {
        didSet { UserDefaults.standard.set(detectsSyntaxByFileExtension, forKey: detectsSyntaxByFileExtensionKey) }
    }

    var warnsWhenOpeningLargeFiles: Bool {
        didSet { UserDefaults.standard.set(warnsWhenOpeningLargeFiles, forKey: warnsWhenOpeningLargeFilesKey) }
    }

    var checksForUpdatesAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksForUpdatesAutomatically, forKey: checksForUpdatesAutomaticallyKey) }
    }

    var sidebarStyle: SidebarStyle {
        didSet { UserDefaults.standard.set(sidebarStyle.rawValue, forKey: sidebarStyleKey) }
    }

    var showSidebarByDefault: Bool {
        didSet { UserDefaults.standard.set(showSidebarByDefault, forKey: showSidebarByDefaultKey) }
    }

    var highlightTheme: HighlightTheme {
        didSet {
            UserDefaults.standard.set(highlightTheme.rawValue, forKey: highlightThemeKey)
            NotificationCenter.default.post(name: .syntaxHighlightSettingsDidChange, object: nil)
        }
    }

    /// Turn off macOS's "add period with double-space" for this app.
    ///
    /// It is a system-wide prose setting and NSTextView exposes no per-view
    /// switch for it — `isAutomaticTextReplacementEnabled = false` does not
    /// cover it. In a code editor it rewrites the document: typing two spaces,
    /// an ordinary thing to do while indenting, produced ". " instead. Setting
    /// the key in this app's own defaults domain is the documented way to opt
    /// out, and it takes precedence over the global value.
    private static func optOutOfProseTextSubstitutions(_ defaults: UserDefaults) {
        defaults.set(false, forKey: "NSAutomaticPeriodSubstitutionEnabled")
    }

    init() {
        let defaults = UserDefaults.standard
        Self.optOutOfProseTextSubstitutions(defaults)
        let savedLaunchBehavior = defaults.string(forKey: launchBehaviorKey)
        launchBehavior = savedLaunchBehavior.flatMap(LaunchBehavior.init(rawValue:)) ?? .reopenLastSession

        defaultLanguage = defaults.string(forKey: defaultLanguageKey) ?? "plaintext"
        let savedEncoding = defaults.string(forKey: defaultEncodingKey)
        defaultEncoding = savedEncoding.flatMap(TextEncoding.init(rawValue:)) ?? .utf8
        let savedLineEnding = defaults.string(forKey: defaultLineEndingKey)
        defaultLineEnding = savedLineEnding.flatMap(TextLineEnding.init(rawValue:)) ?? .lf

        let savedTheme = UserDefaults.standard.string(forKey: themeModeKey)
        themeMode = savedTheme.flatMap(AppThemeMode.init(rawValue:)) ?? .system

        editorFontName = defaults.string(forKey: editorFontNameKey) ?? Self.systemEditorFontName
        let savedSize = defaults.double(forKey: editorFontSizeKey)
        editorFontSize = savedSize > 0 ? savedSize : 13
        let savedIndentation = defaults.string(forKey: defaultIndentationKey)
        defaultIndentation = savedIndentation.flatMap(TextIndentation.init(rawValue:)) ?? .spaces4
        wordWrapByDefault = defaults.object(forKey: wordWrapByDefaultKey) as? Bool ?? true
        showsLineNumbers = defaults.object(forKey: showsLineNumbersKey) as? Bool ?? true
        showsInvisibleCharactersByDefault = defaults.bool(forKey: showsInvisibleCharactersByDefaultKey)

        let lightDefault = NSColor.bestTextEditorForeground(for: NSAppearance(named: .aqua)!)
        let darkDefault = NSColor.bestTextEditorForeground(for: NSAppearance(named: .darkAqua)!)
        editorLightTextColor = defaults.string(forKey: editorLightTextColorKey)
            .flatMap(Self.color(fromHexString:)) ?? lightDefault
        editorDarkTextColor = defaults.string(forKey: editorDarkTextColorKey)
            .flatMap(Self.color(fromHexString:)) ?? darkDefault

        autoSaveEnabled = defaults.bool(forKey: autoSaveEnabledKey)
        let savedDelay = defaults.double(forKey: autoSaveDelayKey)
        autoSaveDelay = savedDelay > 0 ? max(1, min(30, savedDelay)) : 3
        backupDocumentsWhileEditing = defaults.object(forKey: backupDocumentsWhileEditingKey) as? Bool ?? true
        askBeforeClosingUnsavedDocuments = defaults.object(forKey: askBeforeClosingUnsavedDocumentsKey) as? Bool ?? true
        detectsEncodingAutomatically = defaults.object(forKey: detectsEncodingAutomaticallyKey) as? Bool ?? true
        detectsSyntaxByFileExtension = defaults.object(forKey: detectsSyntaxByFileExtensionKey) as? Bool ?? true
        warnsWhenOpeningLargeFiles = defaults.object(forKey: warnsWhenOpeningLargeFilesKey) as? Bool ?? true
        checksForUpdatesAutomatically = defaults.object(forKey: checksForUpdatesAutomaticallyKey) as? Bool ?? true
        let savedSidebarStyle = defaults.string(forKey: sidebarStyleKey)
        sidebarStyle = savedSidebarStyle.flatMap(SidebarStyle.init(rawValue:)) ?? .automatic
        let savedHighlightTheme = defaults.string(forKey: highlightThemeKey)
        highlightTheme = savedHighlightTheme.flatMap(HighlightTheme.init(rawValue:)) ?? .adaptive
        showSidebarByDefault = defaults.object(forKey: showSidebarByDefaultKey) as? Bool ?? false
        Self.current = self
    }

    static var availableEditorFontNames: [String] {
        [systemEditorFontName] + NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func editorFont() -> NSFont {
        if let cachedEditorFont { return cachedEditorFont }
        let size = CGFloat(editorFontSize)
        let font: NSFont
        if editorFontName == Self.systemEditorFontName {
            font = NSFont.systemFont(ofSize: size)
        } else {
            font = NSFont(name: editorFontName, size: size)
                ?? NSFont.systemFont(ofSize: size)
        }
        cachedEditorFont = font
        return font
    }

    /// Returns true when syntax and text colors should use the dark palette,
    /// respecting the user's Highlight Theme setting (.oneDark/.oneLight override appearance).
    func isDarkHighlight(for appearance: NSAppearance) -> Bool {
        switch highlightTheme {
        case .adaptive: return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .oneDark:  return true
        case .oneLight: return false
        }
    }

    func editorTextColor(for appearance: NSAppearance) -> NSColor {
        isDarkHighlight(for: appearance) ? editorDarkTextColor : editorLightTextColor
    }

    static func displayName(forEditorFontName fontName: String) -> String {
        fontName == systemEditorFontName ? "System Default" : fontName
    }

    func resetEditorAppearance() {
        editorFontName = Self.systemEditorFontName
        editorFontSize = 13
        editorLightTextColor = NSColor.bestTextEditorForeground(for: NSAppearance(named: .aqua)!)
        editorDarkTextColor = NSColor.bestTextEditorForeground(for: NSAppearance(named: .darkAqua)!)
    }

    private func notifyEditorAppearanceChanged() {
        NotificationCenter.default.post(name: .editorAppearanceDidChange, object: nil)
    }

    private static func color(fromHexString hexString: String) -> NSColor? {
        let trimmed = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let raw = Int(trimmed, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((raw >> 16) & 0xFF) / 255,
            green: CGFloat((raw >> 8) & 0xFF) / 255,
            blue: CGFloat(raw & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func hexString(from color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let red = Int(round(max(0, min(1, srgb.redComponent)) * 255))
        let green = Int(round(max(0, min(1, srgb.greenComponent)) * 255))
        let blue = Int(round(max(0, min(1, srgb.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
