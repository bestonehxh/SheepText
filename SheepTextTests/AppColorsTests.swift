import AppKit
import XCTest
@testable import SheepText

@MainActor
final class AppColorsTests: XCTestCase {
    func testNativeCleanAccentMatchesApprovedDesign() throws {
        XCTAssertEqual(try hex(.bestTextAccent, appearance: .aqua), "#2874C6")
        XCTAssertEqual(try hex(.bestTextAccent, appearance: .darkAqua), "#61AFEF")
    }

    func testNativeCleanCoreSurfacesMatchApprovedDesign() throws {
        XCTAssertEqual(try hex(.bestTextChromeBackground, appearance: .aqua), "#D9E0E8")
        XCTAssertEqual(try hex(.bestTextSidebarBackground, appearance: .aqua), "#E9EEF4")
        XCTAssertEqual(try hex(.bestTextEditorBackground, appearance: .aqua), "#FBFCFE")
        XCTAssertEqual(try hex(.bestTextChromeBackground, appearance: .darkAqua), "#21252B")
        XCTAssertEqual(try hex(.bestTextSidebarBackground, appearance: .darkAqua), "#252A31")
        XCTAssertEqual(try hex(.bestTextEditorBackground, appearance: .darkAqua), "#282C34")
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
