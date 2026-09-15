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
    private let lastAutomaticUpdateCheckKey = "sheeptext.updates.lastAutomaticCheck"
    private let themeModeKey = "sheeptext.themeMode"
    private let editorFontNameKey = "sheeptext.editor.fontName"
    private let editorFontSizeKey = "sheeptext.editor.fontSize"
    private let editorFontWeightKey = "sheeptext.editor.fontWeight"
    private let editorFontSmoothingKey = "sheeptext.editor.fontSmoothing"
    private let defaultIndentationKey = "sheeptext.editor.defaultIndentation"
    private let wordWrapByDefaultKey = "sheeptext.editor.wordWrapByDefault"
    private let showsLineNumbersKey = "sheeptext.editor.showsLineNumbers"
    private let showsInvisibleCharactersByDefaultKey = "sheeptext.editor.showsInvisibleCharactersByDefault"
    private let editorLightTextColorKey = "sheeptext.editor.lightTextColor"
    private let editorDarkTextColorKey = "sheeptext.editor.darkTextColor"
    private let autoSaveEnabledKey = "sheeptext.save.autoSaveEnabled"
    private let autoSaveDelayKey = "sheeptext.save.autoSaveDelay"
    private let chromeStyleKey = "sheeptext.appearance.chromeStyle"
    private let highlightThemeKey = "sheeptext.syntax.highlightTheme"
    private let showSidebarByDefaultKey = "sheeptext.appearance.showSidebarByDefault"

    var launchBehavior: LaunchBehavior {
        didSet { AppStorageLocation.defaults.set(launchBehavior.rawValue, forKey: launchBehaviorKey) }
    }

    var defaultLanguage: String {
        didSet { AppStorageLocation.defaults.set(defaultLanguage, forKey: defaultLanguageKey) }
    }

    var defaultEncoding: TextEncoding {
        didSet { AppStorageLocation.defaults.set(defaultEncoding.rawValue, forKey: defaultEncodingKey) }
    }

    var defaultLineEnding: TextLineEnding {
        didSet { AppStorageLocation.defaults.set(defaultLineEnding.rawValue, forKey: defaultLineEndingKey) }
    }

    var themeMode: AppThemeMode {
        didSet {
            AppStorageLocation.defaults.set(themeMode.rawValue, forKey: themeModeKey)
            // Notification posted from SheepTextApp.applyTheme() *after* NSApp.appearance
            // is set, so effectiveAppearance is correct when observers re-highlight.
        }
    }

    var editorFontName: String {
        didSet {
            cachedEditorFont = nil
            AppStorageLocation.defaults.set(editorFontName, forKey: editorFontNameKey)
            notifyEditorAppearanceChanged()
        }
    }

    /// The Settings slider's range; a trackpad pinch is clamped to the same one.
    static let editorFontSizeRange: ClosedRange<Double> = 9...36

    var editorFontSize: Double {
        didSet {
            cachedEditorFont = nil
            AppStorageLocation.defaults.set(editorFontSize, forKey: editorFontSizeKey)
            notifyEditorAppearanceChanged()
        }
    }

    /// Editor text weight. Medium by default: on a display running a scaled
    /// resolution (the 13″ Air's stock 1470 × 956) the whole screen is
    /// resampled before it reaches the eye, and a Regular face loses more of
    /// its edge to that than a Medium one does.
    enum EditorFontWeight: String, CaseIterable, Identifiable {
        case regular, medium, semibold, bold
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .regular: return "Regular"
            case .medium: return "Medium"
            case .semibold: return "Semibold"
            case .bold: return "Bold"
            }
        }
        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    var editorFontWeight: EditorFontWeight {
        didSet {
            cachedEditorFont = nil
            AppStorageLocation.defaults.set(editorFontWeight.rawValue, forKey: editorFontWeightKey)
            notifyEditorAppearanceChanged()
        }
    }

    /// macOS "font smoothing" — the stroke dilation CoreText applies before
    /// antialiasing. Off by default: on light text over a dark ground it reads
    /// as a grey halo around every stem; without it the same face draws 2 px
    /// stems with a clean edge at 2x (measured against SheepTerm and the
    /// Claude app on this display). The editor's layout manager, gutter and
    /// invisible-character painter all read `DiffLayoutManager.fontSmoothing`,
    /// which this keeps in sync.
    var editorFontSmoothing: Bool {
        didSet {
            AppStorageLocation.defaults.set(editorFontSmoothing, forKey: editorFontSmoothingKey)
            DiffLayoutManager.fontSmoothing = editorFontSmoothing
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
            AppStorageLocation.defaults.set(defaultIndentation.rawValue, forKey: defaultIndentationKey)
            notifyEditorAppearanceChanged()
        }
    }

    var wordWrapByDefault: Bool {
        didSet {
            AppStorageLocation.defaults.set(wordWrapByDefault, forKey: wordWrapByDefaultKey)
            notifyEditorAppearanceChanged()
        }
    }

    var showsLineNumbers: Bool {
        didSet {
            AppStorageLocation.defaults.set(showsLineNumbers, forKey: showsLineNumbersKey)
            notifyEditorAppearanceChanged()
        }
    }

    var showsInvisibleCharactersByDefault: Bool {
        didSet {
            AppStorageLocation.defaults.set(showsInvisibleCharactersByDefault, forKey: showsInvisibleCharactersByDefaultKey)
            notifyEditorAppearanceChanged()
        }
    }

    var editorLightTextColor: NSColor {
        didSet {
            AppStorageLocation.defaults.set(Self.hexString(from: editorLightTextColor), forKey: editorLightTextColorKey)
            notifyEditorAppearanceChanged()
        }
    }

    var editorDarkTextColor: NSColor {
        didSet {
            AppStorageLocation.defaults.set(Self.hexString(from: editorDarkTextColor), forKey: editorDarkTextColorKey)
            notifyEditorAppearanceChanged()
        }
    }

    var autoSaveEnabled: Bool {
        didSet {
            AppStorageLocation.defaults.set(autoSaveEnabled, forKey: autoSaveEnabledKey)
        }
    }

    var backupDocumentsWhileEditing: Bool {
        didSet { AppStorageLocation.defaults.set(backupDocumentsWhileEditing, forKey: backupDocumentsWhileEditingKey) }
    }

    var askBeforeClosingUnsavedDocuments: Bool {
        didSet { AppStorageLocation.defaults.set(askBeforeClosingUnsavedDocuments, forKey: askBeforeClosingUnsavedDocumentsKey) }
    }

    var autoSaveDelay: Double {
        didSet {
            let clamped = max(1, min(30, autoSaveDelay))
            if clamped != autoSaveDelay {
                autoSaveDelay = clamped
                return
            }
            AppStorageLocation.defaults.set(autoSaveDelay, forKey: autoSaveDelayKey)
        }
    }

    var detectsEncodingAutomatically: Bool {
        didSet { AppStorageLocation.defaults.set(detectsEncodingAutomatically, forKey: detectsEncodingAutomaticallyKey) }
    }

    var detectsSyntaxByFileExtension: Bool {
        didSet { AppStorageLocation.defaults.set(detectsSyntaxByFileExtension, forKey: detectsSyntaxByFileExtensionKey) }
    }

    var warnsWhenOpeningLargeFiles: Bool {
        didSet { AppStorageLocation.defaults.set(warnsWhenOpeningLargeFiles, forKey: warnsWhenOpeningLargeFilesKey) }
    }

    var checksForUpdatesAutomatically: Bool {
        didSet { AppStorageLocation.defaults.set(checksForUpdatesAutomatically, forKey: checksForUpdatesAutomaticallyKey) }
    }

    /// When the last *automatic* update check ran. `UpdateChecker` throttles
    /// launch-time checks against this; the menu item ignores it.
    /// nil means "never checked".
    var lastAutomaticUpdateCheck: Date? {
        didSet {
            if let lastAutomaticUpdateCheck {
                AppStorageLocation.defaults.set(lastAutomaticUpdateCheck, forKey: lastAutomaticUpdateCheckKey)
            } else {
                AppStorageLocation.defaults.removeObject(forKey: lastAutomaticUpdateCheckKey)
            }
        }
    }

    /// Material used for the tab bar and sidebar. See `GlassChrome.swift`.
    var chromeStyle: ChromeStyle {
        didSet {
            AppStorageLocation.defaults.set(chromeStyle.rawValue, forKey: chromeStyleKey)
            NotificationCenter.default.post(name: .editorAppearanceDidChange, object: nil)
        }
    }

    var showSidebarByDefault: Bool {
        didSet { AppStorageLocation.defaults.set(showSidebarByDefault, forKey: showSidebarByDefaultKey) }
    }

    var highlightTheme: HighlightTheme {
        didSet {
            AppStorageLocation.defaults.set(highlightTheme.rawValue, forKey: highlightThemeKey)
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
        // AppKit reads this key from the app's own domain, so it goes to
        // `.standard` even while everything of ours goes elsewhere under XCTest.
        Self.optOutOfProseTextSubstitutions(.standard)
        let defaults = AppStorageLocation.defaults
        let savedLaunchBehavior = defaults.string(forKey: launchBehaviorKey)
        launchBehavior = savedLaunchBehavior.flatMap(LaunchBehavior.init(rawValue:)) ?? .reopenLastSession

        defaultLanguage = defaults.string(forKey: defaultLanguageKey) ?? "plaintext"
        let savedEncoding = defaults.string(forKey: defaultEncodingKey)
        defaultEncoding = savedEncoding.flatMap(TextEncoding.init(rawValue:)) ?? .utf8
        let savedLineEnding = defaults.string(forKey: defaultLineEndingKey)
        defaultLineEnding = savedLineEnding.flatMap(TextLineEnding.init(rawValue:)) ?? .lf

        let savedTheme = AppStorageLocation.defaults.string(forKey: themeModeKey)
        // Dark is the default the app ships with: the chrome is glass, and a
        // dark ground is what keeps the material reading as material rather
        // than as a washed-out grey. System Default is still one click away.
        themeMode = savedTheme.flatMap(AppThemeMode.init(rawValue:)) ?? .dark

        editorFontName = defaults.string(forKey: editorFontNameKey) ?? Self.systemEditorFontName
        let savedSize = defaults.double(forKey: editorFontSizeKey)
        editorFontSize = savedSize > 0 ? savedSize : 13
        editorFontWeight = defaults.string(forKey: editorFontWeightKey)
            .flatMap(EditorFontWeight.init(rawValue:)) ?? .medium
        let savedSmoothing = defaults.object(forKey: editorFontSmoothingKey) as? Bool ?? false
        editorFontSmoothing = savedSmoothing
        DiffLayoutManager.fontSmoothing = savedSmoothing
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
        lastAutomaticUpdateCheck = defaults.object(forKey: lastAutomaticUpdateCheckKey) as? Date
        let savedChromeStyle = defaults.string(forKey: chromeStyleKey)
        chromeStyle = savedChromeStyle.flatMap(ChromeStyle.init(rawValue:)) ?? .glass
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
        let weight = editorFontWeight.nsWeight
        let font: NSFont
        if editorFontName == Self.systemEditorFontName {
            font = NSFont.systemFont(ofSize: size, weight: weight)
        } else {
            // Ask the family for the requested weight; a family without that
            // face gets its closest member, and one that has vanished falls
            // back to the system font at the same weight.
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: editorFontName,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            let byDescriptor = NSFont(descriptor: descriptor, size: size)
            let matches = byDescriptor.map { $0.familyName == editorFontName } ?? false
            font = (matches ? byDescriptor : nil)
                ?? NSFont(name: editorFontName, size: size)
                ?? NSFont.systemFont(ofSize: size, weight: weight)
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
        editorFontWeight = .medium
        editorFontSmoothing = false
        editorLightTextColor = NSColor.bestTextEditorForeground(for: NSAppearance(named: .aqua)!)
        editorDarkTextColor = NSColor.bestTextEditorForeground(for: NSAppearance(named: .darkAqua)!)
    }

    /// Coalescing window for `.editorAppearanceDidChange`.
    ///
    /// Every observer of that notification clears its syntax-highlight cache and
    /// re-highlights the whole document. Dragging the font-size slider from 9 to
    /// 36 posts it once per step — 27 full re-highlights for one gesture.
    static let editorAppearanceCoalescingWindow: TimeInterval = 0.15

    @ObservationIgnored private var appearanceCoalesceTimer: Timer?
    /// A change arrived while the coalescing window was already open, so the
    /// trailing edge still has something to say.
    @ObservationIgnored private var appearanceChangePending = false

    /// Leading + trailing edge, deliberately.
    ///
    /// Trailing-only would make a slider drag feel dead — nothing would move
    /// until the user let go. Leading-edge keeps the common case (one click on a
    /// stepper, a font-name pick, a checkbox) exactly as immediate as it was,
    /// and collapses everything that follows inside the window into ONE trailing
    /// post. A 27-step drag costs 2 re-highlights instead of 27.
    ///
    /// The timer runs in `.common` modes: a slider drag puts the run loop in
    /// `.eventTracking`, where a plain scheduled timer would not fire at all
    /// until the mouse came up, so the editor would freeze mid-drag rather than
    /// following it at ~7 fps.
    ///
    /// The window is NOT restarted by a change that lands inside it. It used to
    /// be, which made this a debounce: a gesture sending a step faster than the
    /// window (a trackpad pinch, a quick slider drag) got nothing after the
    /// leading post until it stopped.
    private func notifyEditorAppearanceChanged() {
        guard appearanceCoalesceTimer == nil else {
            appearanceChangePending = true
            return
        }
        NotificationCenter.default.post(name: .editorAppearanceDidChange, object: nil)

        let timer = Timer(timeInterval: Self.editorAppearanceCoalescingWindow, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.appearanceCoalesceTimer = nil
                guard self.appearanceChangePending else { return }
                self.appearanceChangePending = false
                NotificationCenter.default.post(name: .editorAppearanceDidChange, object: nil)
            }
        }
        appearanceCoalesceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
