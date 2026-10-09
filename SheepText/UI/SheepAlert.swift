import AppKit
import SwiftUI

/// Every alert in the app: a drop-in for `NSAlert` — same properties, same
/// `addButton` order and response codes (`.alertFirstButtonReturn` …),
/// `runModal()` — drawn as one centred column on rounded glass. Ported from
/// SheepTerm's `SheepAlert` (9 Oct 2026, the user: the Save-changes popup's
/// icon hugged the left edge; every popup is centred like SheepTerm's).
///
/// Why not NSAlert: on macOS 26 it centres its icon and title only while the
/// text block is short (about three rendered lines, no accessory view, two
/// buttons); past that it flips to the left-aligned layout and nothing public
/// turns that off. "Save changes to …?" with three buttons was already over
/// the line. Here the layout never changes with the length of the text.
///
/// Kept from NSAlert on purpose, because call sites rely on it:
///   • the first button is the default (Return);
///   • a button titled "Cancel" answers Escape wherever it is, and
///     "Don't Save" answers ⌘D;
///   • destructive buttons (Delete…, Remove…, or `hasDestructiveAction`) are
///     red, the default is the family's soft blue, Cancel sits last and is
///     never drawn blue. Only the ORDER ON SCREEN changes; response codes
///     follow `addButton` order.
///
/// Added: a text field in the accessory view (Go to Line, New File) takes
/// the focus when the panel opens, so the user can type straight away.
@MainActor
final class SheepAlert: NSObject {
    var messageText = ""
    var informativeText = ""
    /// Accepted for call-site compatibility; every alert reads the same.
    var alertStyle: NSAlert.Style = .warning
    var accessoryView: NSView?
    private(set) var buttons: [NSButton] = []

    private var panel: Panel?

    static let contentWidth: CGFloat = 288

    @discardableResult
    func addButton(withTitle title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(buttonPressed(_:)))
        button.bezelStyle = .push
        button.controlSize = .large
        button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttons.count
        if buttons.isEmpty {
            button.keyEquivalent = "\r"
        } else if title == "Cancel" {
            button.keyEquivalent = "\u{1b}"
        } else if title == "Don't Save" {
            button.keyEquivalent = "d"
            button.keyEquivalentModifierMask = .command
        }
        buttons.append(button)
        return button
    }

    /// The panel (built on first use).
    var window: NSWindow { build() }

    /// Discardable like NSAlert's: a one-button "OK" alert has nothing to
    /// read back.
    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        let panel = build()
        Self.center(panel, over: NSApp.keyWindow ?? NSApp.mainWindow)
        let response = NSApp.runModal(for: panel)
        // orderOut, NOT close(): close() can post the last-window-closed
        // question when the alert is the only window on screen.
        panel.orderOut(nil)
        return response
    }

    /// Centred on the window the user is looking at, not on the screen — on
    /// a wide display `NSWindow.center()` puts the alert well away from a
    /// window that sits to one side. No window → screen centre.
    static func center(_ panel: NSWindow, over window: NSWindow?) {
        guard let window, window !== panel, window.isVisible else { panel.center(); return }
        let host = window.frame
        let size = panel.frame.size
        var origin = NSPoint(x: host.midX - size.width / 2, y: host.midY - size.height / 2)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
    }

    /// Escape: press "Cancel" if there is one.
    fileprivate func cancel() {
        buttons.first(where: Self.isCancel)?.performClick(nil)
    }

    // MARK: - Building

    fileprivate final class Panel: NSPanel {
        weak var owner: SheepAlert?
        /// The painted (borderless) default button is not the window's
        /// default button, so the panel answers Return for it.
        weak var returnButton: NSButton?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { owner?.cancel() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if let returnButton, event.type == .keyDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
               event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" {
                returnButton.performClick(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    static func isDestructive(_ button: NSButton) -> Bool {
        button.hasDestructiveAction || button.title.hasPrefix("Delete") || button.title.hasPrefix("Remove")
    }

    static func isCancel(_ button: NSButton) -> Bool { button.title.hasPrefix("Cancel") }

    /// The family's alert colours (SheepTerm 4.2 (2)): the soft blue macOS 26
    /// gives an alert's default button in a dark window, and a red in the
    /// same tone. Drawn by hand because `bezelColor` and the default tint
    /// only show while the window is key.
    static let defaultBlue = NSColor(srgbRed: 0.42, green: 0.64, blue: 0.82, alpha: 1)
    static let destructiveRed = NSColor(srgbRed: 0.84, green: 0.45, blue: 0.45, alpha: 1)

    /// A filled capsule in `color` with white text, the height of a large
    /// push button.
    private static func paint(_ button: NSButton, _ color: NSColor) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = color.cgColor
        button.layer?.cornerRadius = 14
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold),
        ])
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func build() -> Panel {
        if let panel { return panel }
        if buttons.isEmpty { addButton(withTitle: "OK") }
        let width = Self.contentWidth

        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: width + 56, height: 200),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.owner = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }

        var rows: [NSView] = []

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])
        rows.append(iconView)

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .centerX
        text.spacing = 6
        if !messageText.isEmpty {
            text.addArrangedSubview(Self.label(messageText,
                                               font: .systemFont(ofSize: 14, weight: .semibold),
                                               color: .labelColor))
        }
        if !informativeText.isEmpty {
            text.addArrangedSubview(Self.label(informativeText,
                                               font: .systemFont(ofSize: 12),
                                               color: .secondaryLabelColor))
        }
        rows.append(text)

        if let accessoryView {
            // An accessory arrives with its own frame (as NSAlert expects);
            // keep that size, never wider than the text column.
            let size = accessoryView.frame.size
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                accessoryView.widthAnchor.constraint(equalToConstant: min(max(size.width, 1), width)),
                accessoryView.heightAnchor.constraint(equalToConstant: max(size.height, 1)),
            ])
            rows.append(accessoryView)
            panel.initialFirstResponder = Self.firstTextField(in: accessoryView)
        }

        // Cancel is never painted as the default: where Cancel answers
        // Return (the external-change alert), the panel maps Return to it
        // instead of the button's key equivalent.
        for button in buttons where Self.isCancel(button) && button.keyEquivalent == "\r" {
            button.keyEquivalent = ""
            panel.returnButton = button
        }
        for button in buttons where button.keyEquivalent == "\r" && !Self.isDestructive(button) {
            Self.paint(button, Self.defaultBlue)
            panel.returnButton = button
        }
        // When Cancel holds Return, the first other non-destructive button
        // is still the dialog's main action: blue, but Return stays Cancel.
        if panel.returnButton.map(Self.isCancel) == true,
           let primary = buttons.first(where: { !Self.isCancel($0) && !Self.isDestructive($0) }) {
            Self.paint(primary, Self.defaultBlue)
        }
        for button in buttons where Self.isDestructive(button) {
            Self.paint(button, Self.destructiveRed)
        }

        // A pair sits side by side while both titles fit their half with
        // room to spare; three or more, or a long pair, stack full width.
        let ordered = buttons.filter { !Self.isCancel($0) } + buttons.filter(Self.isCancel)
        let buttonStack = NSStackView(views: ordered)
        let half = (width - 10) / 2
        let pairFits = buttons.count == 2
            && buttons.allSatisfy { $0.attributedTitle.size().width + 32 <= half }
        buttonStack.orientation = pairFits ? .horizontal : .vertical
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = pairFits ? 10 : 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.widthAnchor.constraint(equalToConstant: width).isActive = true
        if !pairFits {
            for button in buttons {
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
            }
        }
        rows.append(buttonStack)

        let column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 16
        column.setCustomSpacing(14, after: iconView)
        column.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false

        let chrome = NSHostingView(rootView: SheepAlertChrome())
        chrome.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(chrome)
        container.addSubview(column)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: container.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: width + 56),
        ])
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width + 56, height: column.fittingSize.height))
        self.panel = panel
        return panel
    }

    private static func firstTextField(in view: NSView) -> NSView? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    private static func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.isSelectable = false
        label.preferredMaxLayoutWidth = contentWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
}

/// SheepTerm's rounded glass, as a background.
private struct SheepAlertChrome: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            // The panel is titled (for key status) with a hidden, full-size
            // titlebar: without this the glass respects the titlebar safe
            // area and slides down under the content.
            .ignoresSafeArea()
    }
}
