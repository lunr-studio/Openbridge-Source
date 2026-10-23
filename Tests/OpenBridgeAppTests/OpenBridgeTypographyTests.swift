import AppKit
import CoreText
import Testing
@testable import OpenBridgeUI

@Suite(.serialized)
struct OpenBridgeTypographyTests {
    @Test func packagedOriginalFontsResolveWithoutSystemSubstitution() throws {
        let registered = OpenBridgeTypography.registerFonts()
        #expect(Set(registered) == Set(OpenBridgeTypography.bundledFontNames))
        for name in OpenBridgeTypography.bundledFontNames {
            let url = try #require(OpenBridgeTypography.bundledFontURL(named: name), "Missing packaged font: \(name)")
            #expect(url.pathExtension == "otf")
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            #expect(CTFontCopyPostScriptName(font) as String == name, "Do not silently substitute a system font")
            let actualURL = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
            #expect(actualURL.standardizedFileURL == url.standardizedFileURL, "A machine-installed font does not prove packaging works")
        }
    }

    @Test func headingBodyAndTimerUseApprovedFonts() {
        OpenBridgeTypography.registerFonts()
        let expected = ["InstrumentSans-Bold": "Instrument Sans", "InstrumentSans-Regular": "Instrument Sans", "GeistMono-Regular": "Geist Mono"]
        for (name, family) in expected {
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            #expect(CTFontCopyFamilyName(font) as String == family)
        }
    }
}
