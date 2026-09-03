//
//  AppColors.swift
//  Graphite & Signal palette.
//
//  Two rules hold this together:
//
//  1. The chrome is ACHROMATIC — because glass already carries whatever tone
//     is behind the window, and a tinted neutral fights it. The light tones
//     are true greys; the dark ones carry a uniform 3–4/255 blue lift
//     (B > G > R), the conventional cool lift that keeps dark UI from reading
//     muddy. Uniform is the point: one surface drifting off the others is the
//     bug. `AppColorsTests.testChromeNeutralsAreTrueGreys` pins it.
//  2. Colour means something. Amber = unsaved / changed, green = saved /
//     added, red = deleted / error, violet = moved. Nothing decorative is
//     coloured, which is exactly what makes those four read at a glance.
//
//  The accent is FIXED at #0A72D6 / #4FA3F7 — the family's icon blue. It was
//  `controlAccentColor` during the redesign, but the app is built around one
//  blue: the icon, the gutter's moved-block violet and the compare legend are
//  all tuned against it, and a user whose system accent is orange got a
//  chrome that no longer agreed with its own icon. Settings' theme-preview
//  cards must use these same two values, not the live system accent.
//

import AppKit

extension NSColor {
    // MARK: - Accent
    //
    // A fixed blue rather than `controlAccentColor`: the system accent is a
    // brighter, more saturated blue that pulls ahead of the status colours,
    // and the whole point of this palette is that colour ranks by meaning.

    static let bestTextAccent = adaptive(light: 0x0A72D6, dark: 0x4FA3F7)

    static func bestTextAccent(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0x0A72D6, dark: 0x4FA3F7, for: appearance)
    }

    // MARK: - Surfaces

    static let bestTextChromeBackground = adaptive(light: 0xEEEEEF, dark: 0x1A1B1D)
    static let bestTextSidebarBackground = adaptive(light: 0xE9E9EB, dark: 0x161719)
    static let bestTextPanelBackground = adaptive(light: 0xF1F1F3, dark: 0x1D1E21)
    static let bestTextInputBackground = adaptive(light: 0xFFFFFF, dark: 0x27282B)
    static let bestTextEditorBackground = adaptive(light: 0xFCFCFD, dark: 0x1A1B1E)

    // MARK: - Content and interaction

    static let bestTextPrimaryForeground = adaptive(light: 0x17181B, dark: 0xE6E7EA)
    static let bestTextSecondaryForeground = adaptive(light: 0x5A5C61, dark: 0x9A9DA4)
    static let bestTextEditorForeground = adaptive(light: 0x2B2D31, dark: 0xD2D4D9)
    static let bestTextBorder = adaptive(light: 0xD7D7DA, dark: 0x2E2F33)
    static let bestTextHoverBackground = adaptive(light: 0xE3E3E6, dark: 0x232427)

    /// Selection is the one interactive fill that carries the accent, so it
    /// follows the user's accent colour too.
    static let bestTextSelectionBackground = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return bestTextAccent(for: appearance).withAlphaComponent(dark ? 0.26 : 0.18)
    }

    /// The caret's line. Its own token because it is painted UNDER text that
    /// has to stay readable — deriving it from the selection fill (which is
    /// sized for a highlight over short runs) made the whole line a blue band.
    static let bestTextCurrentLine = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return bestTextAccent(for: appearance).withAlphaComponent(dark ? 0.13 : 0.08)
    }

    /// Tree glyphs stay neutral — a coloured folder icon would be the only
    /// colour on screen that means nothing.
    static let bestTextFolderIcon = adaptive(light: 0x76797F, dark: 0x8B8E95)
    static let bestTextFileIcon = adaptive(light: 0x8A8D93, dark: 0x7A7D83)

    // MARK: - Status  (the whole colour vocabulary of the app)

    static let bestTextSuccess = adaptive(light: 0x1F7A45, dark: 0x56BE7F)
    static let bestTextDanger = adaptive(light: 0xB23A3F, dark: 0xE0707A)
    static let editorModifiedAmber = adaptive(light: 0x9C6A12, dark: 0xD9A544)
    static let bestTextMoved = adaptive(light: 0x6E52A6, dark: 0xB294E4)

    // MARK: - Compare and search
    //
    // Same four signals on a neutral ground: the tint carries the meaning and
    // the ground stays grey, so a diff never turns into a colour field.

    static let bestTextCompareChangedLeft = adaptive(light: 0xFAF0EF, dark: 0x2D2628)
    static let bestTextCompareChangedRight = adaptive(light: 0xEFF6F1, dark: 0x222B26)
    static let bestTextCompareRemoved = adaptive(light: 0xFAE9EA, dark: 0x3A2629)
    static let bestTextCompareAdded = adaptive(light: 0xE8F4EC, dark: 0x1F3A2B)
    static let bestTextCompareMoved = adaptive(light: 0xEFECF7, dark: 0x2B2839)
    static let bestTextCompareFiller = adaptive(light: 0xF3F3F5, dark: 0x1D1E21)
    static let bestTextCompareWordRemoved = adaptive(light: 0xF3BCBF, dark: 0x69333A)
    static let bestTextCompareWordAdded = adaptive(light: 0xBADFC7, dark: 0x2E6446)
    static let bestTextSearchMatch = adaptive(light: 0xF2E3A6, dark: 0x5C5026)
    static let bestTextSearchCurrent = adaptive(light: 0xEDC57E, dark: 0x82562A)

    // MARK: - Appearance-specific accessors

    static func bestTextChromeBackground(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0xEEEEEF, dark: 0x1A1B1D, for: appearance)
    }

    static func bestTextEditorBackground(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0xFCFCFD, dark: 0x1A1B1E, for: appearance)
    }

    static func bestTextEditorForeground(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0x2B2D31, dark: 0xD2D4D9, for: appearance)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            resolved(light: light, dark: dark, for: appearance)
        }
    }

    private static func resolved(light: UInt32, dark: UInt32, for appearance: NSAppearance) -> NSColor {
        rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
