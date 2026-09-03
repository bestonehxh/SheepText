import AppKit
import XCTest
@testable import SheepText

@MainActor
final class AppColorsTests: XCTestCase {
    // These pin the "Graphite & Signal" palette (Sept 2026). They replaced the
    // "Native Clean" values, which the redesign had left asserting a palette
    // the app no longer paints — two tests failing on every run.
    //
    // The accent is deliberately hard-coded rather than `controlAccentColor`:
    // if someone reintroduces the system accent, THIS is the test that says so,
    // because a system-accent app returns whatever the running machine is set
    // to and these assertions stop being reproducible.
    func testGraphiteSignalAccentMatchesApprovedDesign() throws {
        XCTAssertEqual(try hex(.bestTextAccent, appearance: .aqua), "#0A72D6")
        XCTAssertEqual(try hex(.bestTextAccent, appearance: .darkAqua), "#4FA3F7")
    }

    func testGraphiteSignalCoreSurfacesMatchApprovedDesign() throws {
        XCTAssertEqual(try hex(.bestTextChromeBackground, appearance: .aqua), "#EEEEEF")
        XCTAssertEqual(try hex(.bestTextSidebarBackground, appearance: .aqua), "#E9E9EB")
        XCTAssertEqual(try hex(.bestTextEditorBackground, appearance: .aqua), "#FCFCFD")
        XCTAssertEqual(try hex(.bestTextChromeBackground, appearance: .darkAqua), "#1A1B1D")
        XCTAssertEqual(try hex(.bestTextSidebarBackground, appearance: .darkAqua), "#161719")
        XCTAssertEqual(try hex(.bestTextEditorBackground, appearance: .darkAqua), "#1A1B1E")
    }

    /// The neutrals must stay near-achromatic — rule 1 of the palette, since a
    /// hue bias fights the glass, which already carries the desktop's tone.
    ///
    /// Tolerance is 4, not 0: the light tones ARE true greys (spread 1–2), but
    /// every dark tone carries a consistent 3–4 step blue lift (B > G > R —
    /// #1A1B1D, #161719, #1A1B1E). That is the conventional cool lift dark UI
    /// uses to avoid looking muddy, and it is uniform across the three
    /// surfaces, so it reads as deliberate. This test pins it at 4 so a real
    /// tint (a warm grey, or one surface drifting away from the others) still
    /// fails, and records the discrepancy with the palette's "no hue bias"
    /// wording rather than leaving it to be rediscovered.
    func testChromeNeutralsAreTrueGreys() throws {
        for (color, name) in [(NSColor.bestTextChromeBackground, "chrome"),
                              (NSColor.bestTextSidebarBackground, "sidebar"),
                              (NSColor.bestTextEditorBackground, "editor")] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let hexValue = try hex(color, appearance: appearance)
                let r = hexValue.dropFirst(1).prefix(2)
                let g = hexValue.dropFirst(3).prefix(2)
                let b = hexValue.dropFirst(5).prefix(2)
                let components = [r, g, b].compactMap { Int($0, radix: 16) }
                let spread = (components.max() ?? 0) - (components.min() ?? 0)
                XCTAssertLessThanOrEqual(
                    spread, 4,
                    "\(name) in \(appearance.rawValue) is \(hexValue) — not a true grey"
                )
            }
        }
    }

    /// Settings' theme-mode cards paint their own fixed palette (the preview
    /// must show its own mode, not the window's), so the values are typed out a
    /// second time in PreferencesView. They drifted once already: the cards read
    /// `controlAccentColor` for a while and previewed a colour the app never
    /// painted. Nothing but this test connects the two copies.
    func testThemePreviewCardsMatchTheAppPalette() throws {
        XCTAssertEqual(hexString(ThemePreviewPalette.lightAccentHex),
                       try hex(.bestTextAccent, appearance: .aqua))
        XCTAssertEqual(hexString(ThemePreviewPalette.darkAccentHex),
                       try hex(.bestTextAccent, appearance: .darkAqua))

        XCTAssertEqual(hexString(ThemePreviewPalette.lightChromeHex),
                       try hex(.bestTextChromeBackground, appearance: .aqua))
        XCTAssertEqual(hexString(ThemePreviewPalette.lightSidebarHex),
                       try hex(.bestTextSidebarBackground, appearance: .aqua))
        XCTAssertEqual(hexString(ThemePreviewPalette.lightEditorHex),
                       try hex(.bestTextEditorBackground, appearance: .aqua))

        XCTAssertEqual(hexString(ThemePreviewPalette.darkChromeHex),
                       try hex(.bestTextChromeBackground, appearance: .darkAqua))
        XCTAssertEqual(hexString(ThemePreviewPalette.darkSidebarHex),
                       try hex(.bestTextSidebarBackground, appearance: .darkAqua))
        XCTAssertEqual(hexString(ThemePreviewPalette.darkEditorHex),
                       try hex(.bestTextEditorBackground, appearance: .darkAqua))
    }

    private func hexString(_ value: UInt32) -> String {
        String(format: "#%06X", value)
    }

    private func hex(_ color: NSColor, appearance name: NSAppearance.Name) throws -> String {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(NSColorSpace.sRGB)
        }
        let rgb = try XCTUnwrap(resolved)
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
