//
//  TabBarView.swift
//  Horizontal tab bar above the editor. Always visible — even with zero
//  open documents — so the "+" button for creating/opening tabs is always
//  reachable.
//
//  Drag-reorder logic keeps the real document order stable while dragging.
//  The dragged tab follows the cursor, neighbours slide aside after the cursor
//  crosses their midpoint, and the final order commits once on mouse-up.
//

import SwiftUI
import AppKit

struct TabBarView: View {

    @Environment(DocumentStore.self)  private var documents
    @Environment(WorkspaceStore.self) private var workspace
    let onToggleSidebar: () -> Void

    /// Tracked here rather than passed in from the parent so the traffic-light
    /// gap is the ONLY thing that animates. Driving it from parent state made
    /// every unrelated parent change (showing the sidebar) animate this bar.
    @State private var isFullScreen = false

    // Tab geometry, keyed by document ID, in "tabBarScroll" coordinate space.
    @State private var tabFrames: [Document.ID: CGRect] = [:]

    // Drag state
    @State private var draggingID: Document.ID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartFrames: [Document.ID: CGRect] = [:]
    @State private var dragStartOrder: [Document.ID] = []
    @State private var dragSourceIndex: Int?
    @State private var dragTargetIndex: Int?

    init(onToggleSidebar: @escaping () -> Void = {}) {
        self.onToggleSidebar = onToggleSidebar
    }

    // MARK: - Navigation

    private var hasPrevious: Bool {
        guard let id = documents.activeDocumentID,
              let idx = documents.documents.firstIndex(where: { $0.id == id })
        else { return false }
        return idx > 0
    }

    private var hasNext: Bool {
        guard let id = documents.activeDocumentID,
              let idx = documents.documents.firstIndex(where: { $0.id == id })
        else { return false }
        return idx < documents.documents.count - 1
    }

    private func navigatePrevious() {
        guard let id = documents.activeDocumentID,
              let idx = documents.documents.firstIndex(where: { $0.id == id }),
              idx > 0
        else { return }
        documents.activeDocumentID = documents.documents[idx - 1].id
    }

    private func navigateNext() {
        guard let id = documents.activeDocumentID,
              let idx = documents.documents.firstIndex(where: { $0.id == id }),
              idx < documents.documents.count - 1
        else { return }
        documents.activeDocumentID = documents.documents[idx + 1].id
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Room for the traffic lights sharing this row — collapsed in
            // fullscreen where they are hidden. Switched on the will*
            // notifications so the tabs slide over DURING the system
            // transition; switching on did* pops after the animation settles.
            Spacer()
                .frame(width: isFullScreen ? 0 : 72)
                .animation(.easeOut(duration: 0.18), value: isFullScreen)

            HStack(spacing: 0) {
                Button(action: navigatePrevious) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!hasPrevious)
                .help("Previous Tab")

                Button(action: navigateNext) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!hasNext)
                .help("Next Tab")
            }
            .padding(.horizontal, 2)

            Divider().frame(height: 16)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(documents.documents) { doc in
                            TabChip(
                                document: doc,
                                isActive: doc.id == documents.activeDocumentID,
                                isDragging: doc.id == draggingID,
                                dragOffset: dragOffset(for: doc.id),
                                onSelect: { documents.activeDocumentID = doc.id },
                                onClose:  { _ = documents.requestCloseTabFromUI(doc.id) },
                                onDragChanged: { value in handleTabDrag(doc.id, value) },
                                onDragEnded: finishTabDrag
                            )
                            .id(doc.id)
                        }
                    }
                }
                .coordinateSpace(name: "tabBarScroll")
                .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                    tabFrames = frames
                }
                .onChange(of: documents.activeDocumentID) { _, newID in
                    guard draggingID == nil, let id = newID else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }

            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.leading, 6)
            .help("Toggle Sidebar")

            Button { documents.newUntitled() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .help("New untitled file")
        }
        .frame(height: 30)
        // A view background rather than a ShapeStyle one: ShapeStyle
        // backgrounds auto-expand into the titlebar safe area this bar lives
        // in. The drag gesture makes the empty strip move the window, the way
        // a real titlebar does.
        .background(
            Color(nsColor: .bestTextChromeBackground)
                .gesture(WindowDragGesture())
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .bestTextBorder))
                .frame(height: 1)
        }
        .zIndex(1)
        .onAppear {
            isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        // Safety net for aborted/restored transitions that skip the will* pair.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    // MARK: - Helpers

    private func dragOffset(for id: Document.ID) -> CGFloat {
        guard let draggingID,
              let sourceIndex = dragSourceIndex,
              let targetIndex = dragTargetIndex
        else { return 0 }

        if id == draggingID {
            return dragTranslation
        }

        guard let index = dragStartOrder.firstIndex(of: id),
              let draggedWidth = dragStartFrames[draggingID]?.width
        else { return 0 }

        if targetIndex > sourceIndex, index > sourceIndex, index <= targetIndex {
            return -draggedWidth
        }

        if targetIndex < sourceIndex, index >= targetIndex, index < sourceIndex {
            return draggedWidth
        }

        return 0
    }

    // MARK: - Drag handling

    private func handleTabDrag(_ id: Document.ID, _ value: DragGesture.Value) {
        if draggingID == nil {
            draggingID = id
            dragTranslation = 0
            dragStartFrames = tabFrames
            dragStartOrder = documents.documents.map(\.id)
            dragSourceIndex = dragStartOrder.firstIndex(of: id)
            dragTargetIndex = dragSourceIndex
            documents.activeDocumentID = id
        }

        dragTranslation = value.translation.width
        updateDragTarget(for: id)
    }

    private func finishTabDrag() {
        var t = Transaction()
        t.disablesAnimations = true

        if let id = draggingID,
           let sourceIndex = dragSourceIndex,
           let targetIndex = dragTargetIndex,
           dragStartOrder.indices.contains(sourceIndex) {
            var order = dragStartOrder
            order.remove(at: sourceIndex)
            order.insert(id, at: max(0, min(targetIndex, order.count)))

            withTransaction(t) {
                documents.reorderDocuments(matching: order)
                resetDrag()
            }
        } else {
            withTransaction(t) {
                resetDrag()
            }
        }
    }

    private func resetDrag() {
        draggingID = nil
        dragTranslation = 0
        dragStartFrames = [:]
        dragStartOrder = []
        dragSourceIndex = nil
        dragTargetIndex = nil
    }

    private func updateDragTarget(for id: Document.ID) {
        guard let sourceFrame = dragStartFrames[id],
              dragStartOrder.contains(id)
        else { return }

        let draggedMinX = sourceFrame.minX + dragTranslation
        let draggedMaxX = sourceFrame.maxX + dragTranslation
        var targetIndex = 0

        for otherID in dragStartOrder where otherID != id {
            guard let frame = dragStartFrames[otherID] else { continue }

            let passedHalfway: Bool
            if frame.midX > sourceFrame.midX {
                passedHalfway = draggedMaxX >= frame.midX
            } else {
                passedHalfway = draggedMinX > frame.midX
            }

            if passedHalfway {
                targetIndex += 1
            }
        }

        if targetIndex != dragTargetIndex {
            withAnimation(.snappy(duration: 0.14)) {
                dragTargetIndex = targetIndex
            }
        }
    }
}

// MARK: - TabChip

private struct TabChip: View {
    let document: Document
    let isActive: Bool
    let isDragging: Bool
    let dragOffset: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: () -> Void

    @Environment(DocumentStore.self) private var documents
    @State private var isHovering = false
    @State private var isHoveringClose = false

    private var accentColor: Color {
        Color(nsColor: .bestTextAccent)
    }

    private var isInCompare: Bool {
        documents.compareLeftDocumentID == document.id ||
        documents.compareRightDocumentID == document.id
    }

    var body: some View {
        HStack(spacing: 6) {
            if document.wasRecoveredFromDraft {
                Circle()
                    .strokeBorder(Color(nsColor: .editorModifiedAmber), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .help("Recovered draft")
            }

            if isInCompare {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .editorModifiedAmber))
                    .help("Used in Compare")
            }

            Text(document.displayName)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(
                    Color(nsColor: isActive ? .bestTextPrimaryForeground : .bestTextSecondaryForeground)
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            closeControl
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tabBackground)
        .overlay(alignment: .bottom) {
            if isActive {
                accentColor
                    .frame(height: 2)
                    .clipShape(Capsule())
                    .padding(.horizontal, 10)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: [document.id: proxy.frame(in: .named("tabBarScroll"))]
                )
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .offset(x: dragOffset)
        .zIndex(isDragging ? 10 : 0)
        .compositingGroup()
        .transaction { t in if isDragging { t.animation = nil } }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("tabBarScroll"))
                .onChanged(onDragChanged)
                .onEnded { _ in onDragEnded() }
        )
        .help(tabHelp)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .bestTextBorder).opacity(0.72))
                .frame(width: 1, height: 16)
        }
    }

    @ViewBuilder
    private var closeControl: some View {
        Button(action: onClose) {
            ZStack {
                if shouldShowCloseIcon {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                } else if document.isDirty {
                    Circle()
                        .fill(Color(nsColor: .editorModifiedAmber))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(width: 14, height: 14)
        .onHover { isHoveringClose = $0 }
        .help(document.isDirty ? "Unsaved changes. Click to close." : "Close Tab")
    }

    private var shouldShowCloseIcon: Bool {
        isHoveringClose || (!document.isDirty && (isHovering || isActive))
    }

    private var tabBackground: Color {
        if isDragging       { return Color(nsColor: .bestTextSelectionBackground) }
        if isActive         { return Color(nsColor: .bestTextEditorBackground) }
        if isHovering       { return Color(nsColor: .bestTextHoverBackground) }
        return .clear
    }

    private var tabHelp: String {
        var parts = [document.displayName]
        if document.wasRecoveredFromDraft {
            parts.append("Recovered draft")
        }
        parts.append(document.isDirty ? "Unsaved" : "Saved")
        if let path = document.url?.path {
            parts.append(path)
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - PreferenceKey

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Document.ID: CGRect] = [:]
    static func reduce(value: inout [Document.ID: CGRect], nextValue: () -> [Document.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
