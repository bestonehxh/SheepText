//
//  Letterpress.swift
//  The two typographic components the chrome is built from.
//
//  This design replaces file-type icons with the file's own extension, set in
//  monospace: a tree full of `.swift` files is told apart by its NAMES, not by
//  eleven copies of the same glyph. Section headers and tab labels are set as
//  letterspaced uppercase for the same reason — the type does the work the
//  icons and tile backgrounds used to do, which is what keeps the chrome
//  readable once it becomes glass.
//

import SwiftUI
import AppKit

/// The monospace chip carrying a file's extension. Used in the file tree and
/// in tab labels, so a file reads the same way in both places.
struct ExtensionChip: View {
    let filename: String
    var isEmphasized: Bool = false

    /// At most four characters — `.markdown` and friends get clipped rather
    /// than widening every row in the tree.
    private var text: String {
        guard let ext = pressExtension(filename) else { return "—" }
        return String(ext.prefix(4)).uppercased()
    }

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(color)
            .frame(minWidth: 28)
            .padding(.vertical, 2)
            .padding(.horizontal, 3.5)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(color.opacity(isEmphasized ? 0.75 : 0.30), lineWidth: 1)
            )
            .fixedSize()
    }

    private var color: Color {
        isEmphasized
            ? Color(nsColor: .bestTextAccent)
            : Color(nsColor: .bestTextSecondaryForeground)
    }
}

/// A name set the letterpress way: uppercase, letterspaced, small.
/// `emphasis` is what selection and the active tab are drawn with — this
/// design marks state with ink and the accent, never with a filled tile.
struct PressLabel: View {
    let text: String
    var size: CGFloat = 11
    var emphasized: Bool = false
    var color: Color?

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: emphasized ? .semibold : .medium))
            .tracking(size * 0.07)
            .foregroundStyle(color ?? Color(nsColor:
                emphasized ? .bestTextPrimaryForeground : .bestTextSecondaryForeground))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// The part of a filename the chip should carry, or `nil` when there is none
/// worth carrying.
///
/// `NSString.pathExtension` happily calls `2` the extension of `v1.2`, and
/// `2024` that of `backup.2024`. Those are version and date suffixes, not file
/// types: the chip showed a meaningless `2` while `pressBaseName` ate the half
/// of the name that carried the meaning, leaving a row reading `v1`. An
/// all-digit suffix is therefore treated as no extension at all, so the chip
/// falls back to `—` and the label keeps the whole name.
///
/// Leading-dot names (`.gitignore`) already have an empty `pathExtension`, so
/// they need no special case here.
func pressExtension(_ filename: String) -> String? {
    let ext = (filename as NSString).pathExtension
    guard !ext.isEmpty else { return nil }
    guard ext.contains(where: { !$0.isNumber }) else { return nil }
    return ext
}

/// Base name without its extension — the chip already carries the extension,
/// so repeating it in the label wastes the row's width. When the chip is
/// showing nothing (`pressExtension` returned nil) the label keeps the full
/// name, or `backup.2024` would render as `backup` next to an empty chip.
func pressBaseName(_ filename: String) -> String {
    guard pressExtension(filename) != nil else { return filename }
    let base = (filename as NSString).deletingPathExtension
    return base.isEmpty ? filename : base
}
