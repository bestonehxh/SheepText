//
//  AppColors.swift
//  Native Clean semantic colour palette shared by every app surface.
//

import AppKit

extension NSColor {
    // MARK: - Surfaces

    static let bestTextChromeBackground = adaptive(light: 0xD9E0E8, dark: 0x21252B)
    static let bestTextSidebarBackground = adaptive(light: 0xE9EEF4, dark: 0x252A31)
    static let bestTextPanelBackground = adaptive(light: 0xEDF1F5, dark: 0x232830)
    static let bestTextInputBackground = adaptive(light: 0xFFFFFF, dark: 0x2D333C)
    static let bestTextEditorBackground = adaptive(light: 0xFBFCFE, dark: 0x282C34)

    // MARK: - Content and interaction

    static let bestTextPrimaryForeground = adaptive(light: 0x202936, dark: 0xD7DAE0)
    static let bestTextSecondaryForeground = adaptive(light: 0x626D7A, dark: 0x8E96A1)
    static let bestTextEditorForeground = adaptive(light: 0x3D4957, dark: 0xABB2BF)
    static let bestTextBorder = adaptive(light: 0xB8C3CE, dark: 0x414751)
    static let bestTextHoverBackground = adaptive(light: 0xDCE5EF, dark: 0x303741)
    static let bestTextSelectionBackground = adaptive(light: 0xC9DDF4, dark: 0x34445B)
    static let bestTextAccent = adaptive(light: 0x2874C6, dark: 0x61AFEF)
    static let bestTextFolderIcon = adaptive(light: 0x4D76A5, dark: 0x91A3B8)
    static let bestTextFileIcon = adaptive(light: 0x66798D, dark: 0x89929D)

    // MARK: - Status

    static let bestTextSuccess = adaptive(light: 0x27854F, dark: 0x55B879)
    static let bestTextDanger = adaptive(light: 0xC0444B, dark: 0xE06C75)
    static let editorModifiedAmber = adaptive(light: 0xB46B1C, dark: 0xD9A441)
    static let bestTextMoved = adaptive(light: 0x7756B3, dark: 0xC586C0)

    // MARK: - Compare and search

    static let bestTextCompareChangedLeft = adaptive(light: 0xFBEFF0, dark: 0x3B2D32)
    static let bestTextCompareChangedRight = adaptive(light: 0xEEF8F1, dark: 0x2C3B34)
    static let bestTextCompareRemoved = adaptive(light: 0xFBE8E9, dark: 0x4A2C31)
    static let bestTextCompareAdded = adaptive(light: 0xE5F4EA, dark: 0x254238)
    static let bestTextCompareMoved = adaptive(light: 0xEFEAF8, dark: 0x383044)
    static let bestTextCompareFiller = adaptive(light: 0xF0F3F6, dark: 0x24282E)
    static let bestTextCompareWordRemoved = adaptive(light: 0xF3B9BE, dark: 0x743A43)
    static let bestTextCompareWordAdded = adaptive(light: 0xB9DFC6, dark: 0x356B4C)
    static let bestTextSearchMatch = adaptive(light: 0xF6E7A8, dark: 0x665825)
    static let bestTextSearchCurrent = adaptive(light: 0xF2C879, dark: 0x8A5A24)

    // MARK: - Appearance-specific accessors

    static func bestTextChromeBackground(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0xD9E0E8, dark: 0x21252B, for: appearance)
    }

    static func bestTextEditorBackground(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0xFBFCFE, dark: 0x282C34, for: appearance)
    }

    static func bestTextEditorForeground(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0x3D4957, dark: 0xABB2BF, for: appearance)
    }

    static func bestTextAccent(for appearance: NSAppearance) -> NSColor {
        resolved(light: 0x2874C6, dark: 0x61AFEF, for: appearance)
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
