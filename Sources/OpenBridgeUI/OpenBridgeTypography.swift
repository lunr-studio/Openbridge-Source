import AppKit
import CoreText
import SwiftUI

/// App-owned typography from the approved OpenBridge Live identity.
/// The desktop font originals ship locally. Registration never uses the network.
public enum OpenBridgeTypography {
    public static var pageTitle: Font { heading(size: 28) }
    public static var sectionTitle: Font { heading(size: 20) }
    public static var body: Font { body(size: 16) }
    public static var control: Font { body(size: 15, weight: .medium) }
    public static var metadata: Font { body(size: 13) }

    public static func heading(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        let suffix = weight == .regular || weight == .light ? "Regular" : weight == .medium ? "Medium" : "Bold"
        return font(named: "InstrumentSans-\(suffix)", size: size, fallbackWeight: weight, relativeTo: .title)
    }

    public static func body(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(named: "InstrumentSans-\(suffix(for: weight))", size: size, fallbackWeight: weight, relativeTo: .body)
    }

    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(named: "GeistMono-\(suffix(for: weight))", size: size, fallbackWeight: weight, relativeTo: .caption, monospaced: true)
    }

    /// Explicit registration is useful before a native hosting view is created.
    /// The same lazy, thread-safe registration is also invoked by every font role.
    @discardableResult
    public static func registerFonts() -> [String] { registeredFontNames }

    public static let bundledFontNames = [
        "InstrumentSans-Regular", "InstrumentSans-Medium", "InstrumentSans-SemiBold", "InstrumentSans-Bold",
        "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold", "GeistMono-Bold",
    ]

    /// Returns only fonts found in our packaged resource bundle; missing resources
    /// remain a system-font fallback instead of crashing a user's app launch.
    public static func bundledFontURL(named name: String) -> URL? {
        resourceBundle?.url(forResource: name, withExtension: "otf", subdirectory: "Fonts")
    }

    private static let registeredFontNames: [String] = bundledFontNames.compactMap { name in
        guard let url = bundledFontURL(named: name) else { return nil }
        var error: Unmanaged<CFError>?
        let didRegister = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // A host can have registered the same font already. Resolution, rather
        // than a duplicate-registration error, determines whether it is usable.
        if !didRegister { _ = error?.takeRetainedValue() }
        let resolved = CTFontCreateWithName(name as CFString, 16, nil)
        return (CTFontCopyPostScriptName(resolved) as String) == name ? name : nil
    }

    private static func suffix(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: "Bold"
        case .semibold: "SemiBold"
        case .medium: "Medium"
        default: "Regular"
        }
    }

    private static func font(named name: String, size: CGFloat, fallbackWeight: Font.Weight, relativeTo style: Font.TextStyle, monospaced: Bool = false) -> Font {
        guard registeredFontNames.contains(name) else {
            return .system(size: size, weight: fallbackWeight, design: monospaced ? .monospaced : .default)
        }
        return .custom(name, size: size, relativeTo: style)
    }

    private static let resourceBundle: Bundle? = {
        // SwiftPM apps put resource bundles beside the executable; packaged Mac
        // apps put them in Contents/Resources. Avoid Bundle.module's fatalError
        // on incomplete packages so our documented fallback remains real.
        let ownerBundle = Bundle(for: ResourceBundleMarker.self)
        let roots = [Bundle.main.resourceURL,
                     Bundle.main.executableURL?.deletingLastPathComponent(),
                     Bundle.main.bundleURL.deletingLastPathComponent(),
                     ownerBundle.resourceURL,
                     ownerBundle.bundleURL.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            for name in ["OpenBridge_OpenBridgeUI.bundle", "OpenBridge_OpenBridgeUI.resources"] {
                if let bundle = Bundle(url: root.appendingPathComponent(name)) { return bundle }
            }
        }
        return nil
    }()
}

private final class ResourceBundleMarker: NSObject {}

/// Shared colors keep the Research library and the native app on one identity.
public enum OpenBridgePalette {
    public static let ink = Color(red: 20 / 255, green: 32 / 255, blue: 52 / 255)
    public static let mutedInk = Color(red: 93 / 255, green: 108 / 255, blue: 129 / 255)
    public static let canvas = Color(red: 247 / 255, green: 249 / 255, blue: 252 / 255)
    public static let surface = Color.white
    public static let selected = Color(red: 232 / 255, green: 238 / 255, blue: 248 / 255)
    public static let guided = Color(red: 237 / 255, green: 243 / 255, blue: 255 / 255)
    public static let border = Color(red: 225 / 255, green: 231 / 255, blue: 239 / 255)
    public static let controlBorder = Color(red: 126 / 255, green: 140 / 255, blue: 161 / 255)
    public static let blue = Color(red: 35 / 255, green: 103 / 255, blue: 216 / 255)
    public static let gold = Color(red: 246 / 255, green: 200 / 255, blue: 76 / 255)
    public static let localInk = Color(red: 50 / 255, green: 109 / 255, blue: 92 / 255)
    public static let localSurface = Color(red: 239 / 255, green: 246 / 255, blue: 243 / 255)
    public static let cloudInk = Color(red: 82 / 255, green: 96 / 255, blue: 121 / 255)
    public static let cloudSurface = Color(red: 243 / 255, green: 245 / 255, blue: 250 / 255)
    public static let warningInk = Color(red: 133 / 255, green: 84 / 255, blue: 22 / 255)
    public static let warningSurface = Color(red: 255 / 255, green: 246 / 255, blue: 230 / 255)
    public static let errorInk = Color(red: 179 / 255, green: 60 / 255, blue: 60 / 255)
    public static let errorSurface = Color(red: 255 / 255, green: 241 / 255, blue: 240 / 255)
}
