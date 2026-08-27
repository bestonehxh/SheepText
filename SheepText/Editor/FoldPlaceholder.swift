//
//  FoldPlaceholder.swift
//  Inline NSTextAttachment for folded code placeholder.
//

import AppKit

// NSTextAttachment's coding initializers are nonisolated in AppKit.
nonisolated final class FoldPlaceholder: NSTextAttachment {
    let preview: String
    let originalText: String

    init(preview: String, originalText: String) {
        self.preview = preview
        self.originalText = originalText
        super.init(data: nil, ofType: nil)
        image = Self.placeholderImage()
    }

    required init?(coder: NSCoder) {
        self.preview = ""
        self.originalText = ""
        super.init(coder: coder)
        if image == nil {
            image = Self.placeholderImage()
        }
    }

    private static func placeholderImage() -> NSImage {
        // Slightly wider pill so the ellipsis feels balanced and centered.
        let size = NSSize(width: 20, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let ellipse = NSBezierPath(ovalIn: rect)
        let warningColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xD9/255, green: 0xA4/255, blue: 0x41/255, alpha: 1)
                : NSColor(srgbRed: 0xB4/255, green: 0x6B/255, blue: 0x1C/255, alpha: 1)
        }
        warningColor.setFill()
        ellipse.fill()

        // Draw geometric dots so centering is exact and independent of font metrics.
        let dotColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x28/255, green: 0x2C/255, blue: 0x34/255, alpha: 1)
                : NSColor(srgbRed: 0xFB/255, green: 0xFC/255, blue: 0xFE/255, alpha: 1)
        }
        dotColor.setFill()

        let dotDiameter: CGFloat = 1.8
        let dotGap: CGFloat = 2.4
        let totalWidth = dotDiameter * 3 + dotGap * 2
        let startX = (size.width - totalWidth) / 2
        let y = (size.height - dotDiameter) / 2
        for i in 0..<3 {
            let x = startX + CGFloat(i) * (dotDiameter + dotGap)
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
