import Darwin
import Foundation

struct MacCompatibility {
    static let minimumMajorVersion = 14

    let macOSVersion: OperatingSystemVersion
    let chipKind: MacChipKind

    static var current: MacCompatibility {
        MacCompatibility(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            chipKind: detectChipKind()
        )
    }

    var isSupportedOS: Bool {
        macOSVersion.majorVersion >= Self.minimumMajorVersion
    }

    var isSupportedChip: Bool {
        chipKind == .appleSilicon
    }

    var isSupported: Bool {
        isSupportedOS && isSupportedChip
    }

    var macOSVersionLabel: String {
        "macOS \(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)"
    }

    var supportSummary: String {
        switch (isSupportedOS, isSupportedChip) {
        case (true, true):
            return "Openbridge works on Apple silicon Macs running macOS 14 or later."
        case (false, false):
            return "This build needs macOS 14 or later and an Apple silicon Mac."
        case (false, true):
            return "This build needs macOS 14 or later."
        case (true, false):
            return "This build needs an Apple silicon Mac for local transcription."
        }
    }

    private static func detectChipKind() -> MacChipKind {
        var arm64Supported: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &arm64Supported, &size, nil, 0)
        if result == 0 {
            return arm64Supported == 1 ? .appleSilicon : .intel
        }

        #if arch(arm64)
        return .appleSilicon
        #elseif arch(x86_64)
        return .intel
        #else
        return .unknown
        #endif
    }
}

enum MacChipKind: Equatable {
    case appleSilicon
    case intel
    case unknown

    var label: String {
        switch self {
        case .appleSilicon:
            return "Apple silicon"
        case .intel:
            return "Intel Mac"
        case .unknown:
            return "Unknown chip"
        }
    }
}
