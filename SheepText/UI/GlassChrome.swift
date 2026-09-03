//
//  GlassChrome.swift
//  How the app's chrome (tab bar, sidebar, status bar) is painted.
//
//  Ported from SheepTerm's GlassChrome.swift so the family looks the same.
//  This picks the MATERIAL only — the layout is identical either way. Classic
//  paints the same surfaces with the flat `bestText…Background` tiles.
//

import AppKit
import SwiftUI

/// Metrics shared by the two halves of the window's top band — the sidebar's
/// switcher row and the tab bar. They must be the same height or the window
/// grows a second, ragged top edge.
enum SheepTextChromeMetrics {
    static let topBarHeight: CGFloat = 30
}

enum ChromeStyle: String, CaseIterable, Identifiable {
    case glass
    case classic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .glass: return "Liquid Glass"
        case .classic: return "Solid Color"
        }
    }

    /// For AppKit-side readers that cannot see the SwiftUI environment.
    static var current: ChromeStyle {
        AppPreferences.current?.chromeStyle ?? .glass
    }

    var isGlass: Bool { self == .glass }

    // MARK: - Tints for content sitting ON a chrome surface
    //
    // Glass already carries the tone of whatever is behind the window, so the
    // flat tiles stop being backgrounds and start being slabs floating on top
    // of it. Everything painted over glass switches to a translucent tint that
    // lets the material through; classic keeps the palette tiles it was
    // designed around.

    /// Hairline separating chrome surfaces from each other.
    var separator: Color {
        isGlass
            ? Color(nsColor: .bestTextPrimaryForeground).opacity(0.14)
            : Color(nsColor: .bestTextBorder)
    }

    /// Row hover fill. Achromatic on purpose — hover is not a signal, and in
    /// this palette anything coloured is claiming to mean something.
    var hoverFill: Color {
        isGlass
            ? Color(nsColor: .bestTextPrimaryForeground).opacity(0.07)
            : Color(nsColor: .bestTextHoverBackground)
    }

    /// Row selection fill — the one interactive fill allowed to carry the
    /// accent, since "this is the one you picked" IS a meaning.
    var selectionFill: Color {
        isGlass
            ? Color(nsColor: .bestTextAccent).opacity(0.16)
            : Color(nsColor: .bestTextSelectionBackground)
    }

    /// Fill for a panel nested INSIDE a chrome surface (the Find in Files
    /// header). On glass it steps out of the way entirely — the controls it
    /// holds stay opaque on their own.
    var panelFill: Color {
        isGlass ? .clear : Color(nsColor: .bestTextPanelBackground)
    }
}

/// The chrome surfaces that can be painted. The status bar is deliberately
/// never glass: it is a dense strip of 11 pt monospace, not a floating control
/// layer, and glass only costs it contrast.
enum ChromeZone {
    case sidebar, topBar, statusBar

    func isGlass(_ style: ChromeStyle) -> Bool {
        style == .glass && self != .statusBar
    }
}

/// Background for one chrome surface. Always used through the `.background { }`
/// (view builder) form — the ShapeStyle form expands into the titlebar safe
/// area the tab bar lives in and would paint over it.
struct ChromeBackground: View {
    let zone: ChromeZone
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        if zone.isGlass(preferences.chromeStyle) {
            VisualEffectBackground(material: zone == .sidebar ? .sidebar : .headerView)
        } else {
            Color(nsColor: zone == .sidebar ? .bestTextSidebarBackground : .bestTextChromeBackground)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

/// Background for a panel that FLOATS over the editor (the ⌘K palette). Unlike
/// the chrome zones this one blends `.withinWindow`: it sits on the editor, not
/// on the desktop, and a behind-window blur here would punch a hole straight
/// through the document.
struct FloatingPanelBackground: View {
    var cornerRadius: CGFloat = 12
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if preferences.chromeStyle.isGlass {
                WithinWindowEffectBackground(material: .menu)
                    .clipShape(shape)
            } else {
                shape.fill(Color(nsColor: .bestTextPanelBackground))
            }
        }
        .overlay(shape.strokeBorder(preferences.chromeStyle.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }
}

struct WithinWindowEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension View {
    /// Symbol treatment for chrome glyphs. Hierarchical rendering gives the
    /// glyph depth of its own, which is what keeps it legible over a backdrop
    /// that moves; medium is as heavy as a glyph should get on glass, where
    /// semibold thickens into a smudge.
    func chromeSymbol(size: CGFloat, weight: Font.Weight = .medium) -> some View {
        self
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Host-window fullscreen tracking

/// Reports the AppKit window a SwiftUI view is actually hosted in.
///
/// `NSApp.keyWindow` is NOT that window: it is nil while the app is inactive,
/// and it is the *other* window whenever two main windows are open. Chrome that
/// reserves room for the traffic lights has to know about its OWN window or a
/// second window's fullscreen transition collapses the first window's gap while
/// its lights are still drawn.
private struct HostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.onResolve = onResolve
    }

    private final class ProbeView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Hop a tick: this runs inside AppKit's layout pass, and writing
            // SwiftUI state from there is "Modifying state during view update".
            let window = self.window
            let callback = onResolve
            DispatchQueue.main.async { callback?(window) }
        }
    }
}

/// Keeps `isFullScreen` in step with the HOST window only.
///
/// Both halves of the top band need this and they must agree, so it lives in
/// one place: a divergence between them shows up as traffic lights painted
/// over the tabs, or as the sidebar's switcher sliding up into the titlebar
/// strip where this codebase has verified that controls stop taking clicks.
private struct HostWindowFullScreenTracking: ViewModifier {
    @Binding var isFullScreen: Bool
    @State private var hostWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .background {
                HostWindowReader { window in
                    hostWindow = window
                    // Seed from the host window, not NSApp.keyWindow — which is
                    // nil when the app is not active (⌘0 from the background,
                    // or a launch that restores straight into fullscreen).
                    isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            // will*: the gap changes DURING the system transition rather than
            // popping after it. did*: safety net for aborted/restored
            // transitions that skip the will* pair.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if isOwnWindow(note) { isFullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if isOwnWindow(note) { isFullScreen = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
                if isOwnWindow(note) { isFullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                if isOwnWindow(note) { isFullScreen = false }
            }
    }

    private func isOwnWindow(_ note: Notification) -> Bool {
        guard let hostWindow else { return false }
        return (note.object as? NSWindow) === hostWindow
    }
}

extension View {
    /// Track fullscreen for the window THIS view is in. See
    /// `HostWindowFullScreenTracking` for why `NSApp.keyWindow` will not do.
    func trackingHostWindowFullScreen(_ isFullScreen: Binding<Bool>) -> some View {
        modifier(HostWindowFullScreenTracking(isFullScreen: isFullScreen))
    }
}
