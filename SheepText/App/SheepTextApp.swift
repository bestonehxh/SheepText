//
//  SheepTextApp.swift
//  SheepText
//
//  App entry point. Sets up the main WindowGroup, global menu commands,
//  and bootstraps core services + the plugin manager.
//

import SwiftUI
import AppKit
import Carbon
import OSLog

extension Logger {
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Bestchaan.SheepText", category: "app")
}

@main
struct SheepTextApp: App {

    @NSApplicationDelegateAdaptor(SheepTextAppDelegate.self) private var appDelegate

    // Long-lived state objects live at the app level so they survive
    // window open/close cycles.
    @State private var workspace = WorkspaceStore()
    @State private var documents = DocumentStore()
    @State private var commands  = CommandRegistry()
    @State private var palette   = CommandPaletteController()
    @State private var cursor    = CursorState()
    @State private var preferences = AppPreferences()
    // The plugin subsystem was fully built but never instantiated: nothing
    // constructed a PluginManager, so no plugin ever loaded and PluginsView —
    // which reads it out of the environment — would have trapped had anything
    // shown it. It is created here and handed to both scenes.
    @State private var plugins = PluginManager()
    @State private var didRestoreSession = false

    var body: some Scene {
        WindowGroup("SheepText", id: "main") {
            MainWindowView()
                .environment(workspace)
                .environment(documents)
                .environment(commands)
                .environment(palette)
                .environment(cursor)
                .environment(preferences)
                .environment(plugins)
                .preferredColorScheme(preferences.themeMode.colorScheme)
                .tint(Color(nsColor: .bestTextAccent))
                // No .frame here: MainWindowView sets its own minimum size
                // before its .ignoresSafeArea, and a .frame applied after that
                // mis-positions the content expanded into the titlebar row.
                .task {
                    applyTheme()

                    // Register built-in commands before plugins load,
                    // so plugins can override them if they wish.
                    BuiltInCommands.registerAll(
                        into: commands,
                        workspace: workspace,
                        documents: documents,
                        palette: palette
                    )

                    appDelegate.openFilesHandler = { urls in
                        documents.openExternalFileURLs(urls, preferences: preferences)
                    }
                    appDelegate.shouldTerminateHandler = {
                        documents.applicationShouldTerminate()
                    }
                    appDelegate.willTerminateHandler = {
                        documents.flushDirtyDraftsImmediately()
                    }

                    if !didRestoreSession {
                        didRestoreSession = true
                        let launchFileURLs = appDelegate.consumePendingOpenFileURLs()

                        if documents.documents.isEmpty {
                            switch preferences.launchBehavior {
                            case .newBlankDocument:
                                // Only when nothing else is about to open: a
                                // double-clicked file should not also produce a
                                // blank Untitled tab beside it.
                                if launchFileURLs.isEmpty {
                                    documents.newUntitled(preferences: preferences)
                                }
                            case .reopenLastSession:
                                // Restore FIRST, then open the launch files.
                                // Launching by double-clicking a file used to
                                // skip this branch entirely — restoreSessionTabs
                                // is the only caller of restoreDrafts — and then
                                // open() → documents.didSet → persistSession
                                // overwrote the saved session with that single
                                // file, so the user's tabs were gone for good.
                                workspace.restoreLastSessionWorkspace()
                                documents.restoreSessionTabs()
                                if launchFileURLs.isEmpty, documents.activeDocument == nil {
                                    documents.newUntitled(preferences: preferences)
                                }
                            case .showOpenPanel:
                                if launchFileURLs.isEmpty {
                                    let urls = workspace.promptOpenFiles()
                                    for url in urls {
                                        documents.open(url: url, preferences: preferences)
                                    }
                                    if urls.isEmpty {
                                        documents.newUntitled(preferences: preferences)
                                    }
                                }
                            }
                        }

                        // open() dedupes by URL, so a launch file that the
                        // restored session already had simply becomes active.
                        if !launchFileURLs.isEmpty {
                            documents.openExternalFileURLs(launchFileURLs, preferences: preferences)
                        }
                    }

                    await plugins.loadAll(commands: commands, workspace: workspace)

                    UpdateChecker.shared.checkForUpdatesOnLaunchIfDue(preferences: preferences)
                }
                .onOpenURL { url in
                    documents.openExternalFileURLs([url], preferences: preferences)
                }
                .onChange(of: preferences.themeMode) { _, _ in
                    applyTheme()
                }
                .background(ReopenMainWindowBridge(delegate: appDelegate))
        }
        .defaultSize(width: 1200, height: 760)
        // Hidden titlebar so the tab bar can occupy the traffic-light row.
        // The window stays fully standard otherwise: closable, miniaturizable,
        // zoomable and resizable.
        .windowStyle(.hiddenTitleBar)
        .commands {
            SheepTextMenuCommands(
                palette: palette,
                workspace: workspace,
                documents: documents,
                ensureMainWindow: { appDelegate.ensureMainWindowVisible() }
            )
        }

        Settings {
            PreferencesView()
                .environment(preferences)
                .environment(plugins)
                .preferredColorScheme(preferences.themeMode.colorScheme)
                .tint(Color(nsColor: .bestTextAccent))
                .onChange(of: preferences.themeMode) { _, _ in
                    applyTheme()
                }
        }
    }

    @MainActor
    private func applyTheme() {
        NSApp.appearance = preferences.themeMode.appKitAppearance
        NotificationCenter.default.post(name: .editorAppearanceDidChange, object: nil)
    }

}

/// Hands the SwiftUI `openWindow` action to the app delegate so AppKit-side
/// events (Dock click, file open, menu commands) can reopen the main window
/// after the user closed it while Settings stayed open. The closure captured
/// in `onAppear` outlives the window it was installed from.
private struct ReopenMainWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: SheepTextAppDelegate

    var body: some View {
        Color.clear
            .onAppear {
                delegate.reopenMainWindowHandler = { openWindow(id: "main") }
            }
    }
}

@MainActor
final class SheepTextAppDelegate: NSObject, NSApplicationDelegate {
    var openFilesHandler: (([URL]) -> Void)?
    var shouldTerminateHandler: (() -> NSApplication.TerminateReply)?
    var willTerminateHandler: (() -> Void)?
    var reopenMainWindowHandler: (() -> Void)?
    private var pendingOpenFileURLs: [URL] = []

    /// A main editor window (WindowGroup id "main") is on screen or minimised.
    /// The Settings window has its own identifier, so it never counts.
    private var hasMainWindow: Bool {
        NSApp.windows.contains {
            ($0.isVisible || $0.isMiniaturized)
                && ($0.identifier?.rawValue.hasPrefix("main") ?? false)
        }
    }

    func ensureMainWindowVisible() {
        if !hasMainWindow { reopenMainWindowHandler?() }
    }

    /// Dock click / `open -a` on the running app.
    ///
    /// Returning `true` tells AppKit to run its own reopen behaviour *as well*.
    /// When the user had closed the last main window with the red X, that meant
    /// two windows: the one `reopenMainWindowHandler` creates and the one
    /// SwiftUI restores for the WindowGroup. So we only hand the event back to
    /// AppKit when a main window still exists (on screen or minimised in the
    /// Dock) — that is the case where AppKit's default un-miniaturise is
    /// exactly what we want and creating one ourselves would be the duplicate.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasMainWindow else { return true }
        guard let reopenMainWindowHandler else { return true }
        reopenMainWindowHandler()
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(event:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenFileURLs([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        handleOpenFileURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenFileURLs(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shouldTerminateHandler?() ?? .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        willTerminateHandler?()
    }

    @objc
    private func handleOpenDocuments(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        handleOpenFileURLs(fileURLs(from: directObject))
    }

    private func fileURLs(from descriptor: NSAppleEventDescriptor) -> [URL] {
        var urls: [URL] = []

        if descriptor.numberOfItems > 0 {
            for index in 1...descriptor.numberOfItems {
                guard let item = descriptor.atIndex(index),
                      let url = fileURL(from: item)
                else { continue }
                urls.append(url)
            }
            return urls
        }

        if let url = fileURL(from: descriptor) {
            urls.append(url)
        }
        return urls
    }

    private func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        if let url = descriptor.fileURLValue {
            return url
        }

        if let fileURLString = descriptor.coerce(toDescriptorType: DescType(typeFileURL))?.stringValue {
            if let url = URL(string: fileURLString), url.isFileURL {
                return url
            }
            return URL(fileURLWithPath: fileURLString)
        }

        guard let value = descriptor.stringValue, !value.isEmpty else { return nil }
        if let url = URL(string: value), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: value)
    }

    func consumePendingOpenFileURLs() -> [URL] {
        let urls = pendingOpenFileURLs
        pendingOpenFileURLs.removeAll()
        return urls
    }

    private func handleOpenFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let openFilesHandler {
            ensureMainWindowVisible()
            openFilesHandler(urls)
        } else {
            pendingOpenFileURLs.append(contentsOf: urls)
        }
    }
}
