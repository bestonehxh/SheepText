//
//  MainWindowView.swift
//  Top-level layout for a window.
//
//  Custom split layout (no NavigationSplitView): the sidebar is a FULL-HEIGHT
//  column that owns the traffic-light row, and the tab bar spans only the
//  detail pane beside it. Same layout as SheepTerm — one family, one shape —
//  and it is what lets the sidebar's glass be a tall column instead of a
//  stripe across the top of the window.
//
//  NavigationSplitView left a collapsed column frame painted behind the
//  content and animated its own hidden column, so toggling flickered and a
//  ghost sidebar border stayed on screen. A plain HStack has neither problem.
//  ⌘0 toggles the sidebar.
//

import SwiftUI
import AppKit
import Combine

struct MainWindowView: View {

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(DocumentStore.self)  private var documents
    @Environment(CommandPaletteController.self) private var palette
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase

    /// Sidebar visibility. Default controlled by AppPreferences.showSidebarByDefault.
    @State private var sidebarShown: Bool =
        AppPreferences.current?.showSidebarByDefault == true
    @AppStorage("sheeptext.sidebarWidth") private var sidebarWidth: Double = 240
    @State private var selectedPanel: SidebarView.Panel = .files
    @State private var isShowingRecoveredDrafts = false
    /// @State, not `let`. A View is a struct that SwiftUI re-initialises on
    /// every parent update, and `Timer.publish(...).autoconnect()` in a stored
    /// property meant a brand-new timer (and a brand-new subscription) each
    /// time — the 4-second poll restarted from zero on every re-init and, while
    /// the view was updating often, could go long stretches without firing.
    @State private var diskChangeTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                SidebarView(selectedPanel: $selectedPanel)
                    .frame(width: sidebarWidth)
                    // NO .clipped() here. The outer .ignoresSafeArea(.top)
                    // draws this column up into the titlebar row, which puts
                    // that strip OUTSIDE the view's layout bounds — and
                    // `.clipped()` limits hit testing to those bounds, so the
                    // FILES / SEARCH switcher living in the strip stopped
                    // taking clicks (the tab bar, unclipped, kept working,
                    // which is what made this look like a titlebar problem).
                    // Nothing needs the clip: the switcher's own background
                    // covers the rows that scroll under it.
                SidebarResizeHandle(width: $sidebarWidth)
            }

            VStack(spacing: 0) {
                // Spans the detail pane only. It reserves the traffic-light
                // gap itself when the sidebar is hidden, since it is then the
                // view sitting under them.
                TabBarView(
                    onToggleSidebar: toggleSidebar,
                    reservesTrafficLightGap: !sidebarShown
                )
                detailContent
            }
            // ignoresSafeAreaEdges: [] is load-bearing — a plain background
            // auto-expands into the (ignored) titlebar safe area and would
            // paint chrome OVER the tab bar living in that row.
            .background(Color(nsColor: .bestTextChromeBackground), ignoresSafeAreaEdges: [])
        }
        .overlay(alignment: .top) {
            if palette.isVisible {
                CommandPaletteView()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // ⌘0 toggles the sidebar without needing a visible button.
        // A hidden Button is the simplest way to attach a keyboardShortcut
        // that isn't tied to a toolbar item.
        .background(
            Button("") { toggleSidebar() }
                .keyboardShortcut("0", modifiers: .command)
                .hidden()
        )
        .background(WindowChromeConfigurator(themeMode: preferences.themeMode))
        .frame(minWidth: 900, minHeight: 560)
        // Outermost on purpose: a .frame applied after ignoresSafeArea
        // mis-positions the expanded content. This is what pulls the tab bar
        // up into the titlebar row alongside the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.15), value: palette.isVisible)
        .onChange(of: workspace.rootURL) { _, newValue in
            if newValue == nil {
                sidebarShown = false
            } else if preferences.showSidebarByDefault {
                sidebarShown = true
            }
            // If showSidebarByDefault is off, opening/restoring a folder
            // does not force the sidebar open — user controls it with ⌘0.
        }
        .onReceive(NotificationCenter.default.publisher(for: .findInFilesShow)) { _ in
            selectedPanel = .search
            sidebarShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .recoveredDraftsShow)) { _ in
            isShowingRecoveredDrafts = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDraftsFolder)) { _ in
            documents.showDraftsFolder()
        }
        .onReceive(diskChangeTimer) { _ in
            // Nothing open, nothing to stat. (checkForExternalChanges guards
            // this too; keeping it here means the timer tick costs nothing at
            // all in an empty window.)
            guard !documents.documents.isEmpty else { return }
            documents.checkForExternalChanges()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                documents.checkForExternalChanges()
            }
        }
        .sheet(isPresented: $isShowingRecoveredDrafts) {
            RecoveredDraftsView()
                .environment(documents)
        }
    }

    /// A plain flip on purpose: showing the sidebar is a subview swap, and
    /// animating it slides the whole layout (including the tab bar) around.
    private func toggleSidebar() {
        sidebarShown.toggle()
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            EditorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView()
        }
    }
}

/// Thin draggable divider between the sidebar and the editor pane.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var dragStartWidth: Double?
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        Rectangle()
            .fill(preferences.chromeStyle.separator)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = base }
                                width = min(max(base + value.translation.width, 180), 400)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            )
    }
}

private struct RecoveredDraftsView: View {
    @Environment(DocumentStore.self) private var documents
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [RecoveredDraft] = []
    @State private var selectedDraftID: RecoveredDraft.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if drafts.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(drafts) { draft in
                                draftRow(draft)
                                Divider()
                            }
                        }
                    }
                    .frame(width: 360)

                    Divider()
                    previewPane
                }
            }

            Divider()
            footer
        }
        .frame(width: 860, height: 480)
        .background(Color(nsColor: .bestTextPanelBackground))
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(nsColor: .editorModifiedAmber))
            Text("Recovered Drafts")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("\(drafts.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No recovered drafts")
                .font(.system(size: 14, weight: .medium))
            Text("Dirty unsaved tabs appear here after the draft autosave runs.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button("Show Drafts Folder") {
                documents.showDraftsFolder()
            }
            Spacer()
            Button("Refresh") {
                refresh()
            }
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var selectedDraft: RecoveredDraft? {
        guard let selectedDraftID else { return drafts.first }
        return drafts.first { $0.id == selectedDraftID }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = selectedDraft {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(draft.pathDisplay)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Open") {
                        _ = documents.openRecoveredDraft(draft.id)
                        dismiss()
                    }
                    .controlSize(.small)
                }
                .padding(12)

                Divider()

                ScrollView {
                    Text(draft.preview.isEmpty ? " " : draft.preview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .background(Color(nsColor: .bestTextEditorBackground))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draftRow(_ draft: RecoveredDraft) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(draft.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(draft.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(draft.pathDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Text(draft.languageName)
                    Text(draft.encodingName)
                    Text("\(draft.characterCount) chars")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Open") {
                _ = documents.openRecoveredDraft(draft.id)
                dismiss()
            }
            .controlSize(.small)

            Button("Reveal") {
                documents.revealRecoveredDraft(draft.id)
            }
            .controlSize(.small)

            Button("Delete") {
                documents.deleteRecoveredDraft(draft.id)
                refresh()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            selectedDraft?.id == draft.id
                ? Color(nsColor: .bestTextSelectionBackground)
                : Color.clear
        )
        .onTapGesture {
            selectedDraftID = draft.id
        }
    }

    private func refresh() {
        drafts = documents.recoveredDrafts()
        if selectedDraftID == nil || !drafts.contains(where: { $0.id == selectedDraftID }) {
            selectedDraftID = drafts.first?.id
        }
    }
}

/// Configures the hosting window for the hidden-titlebar layout: transparent
/// titlebar so the tab bar shows through, no toolbar, and a chrome-coloured
/// background so the fullscreen reveal strip blends with the tab bar.
private struct WindowChromeConfigurator: NSViewRepresentable {
    let themeMode: AppThemeMode

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: view.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window, window.styleMask.contains(.fullSizeContentView) else { return }

        // Standard window controls: close, minimise, zoom, and live resize.
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = backgroundColor(for: window)
        window.isMovableByWindowBackground = false
        window.toolbar = nil
    }

    private func backgroundColor(for window: NSWindow) -> NSColor {
        switch themeMode {
        case .dark:
            NSColor.bestTextChromeBackground(for: NSAppearance(named: .darkAqua) ?? window.effectiveAppearance)
        case .light:
            NSColor.bestTextChromeBackground(for: NSAppearance(named: .aqua) ?? window.effectiveAppearance)
        case .system:
            NSColor.bestTextChromeBackground(for: window.effectiveAppearance)
        }
    }

}
