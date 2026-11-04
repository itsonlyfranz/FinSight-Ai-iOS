import SwiftUI
import UIKit

/// The three colour themes of the Android app, with the same identifiers so a stored choice
/// reads the same on both platforms. Each palette has a dark variant (Android's colours) and a
/// light variant (Android's light scheme with the palette's primary darkened for text contrast).
enum ThemePalette: String, CaseIterable, Identifiable, Sendable {
    case deckEmerald = "DECK_EMERALD"
    case cyberSlate = "CYBER_SLATE"
    case midnightBlue = "MIDNIGHT_BLUE"

    /// `UserDefaults` key, also usable as a launch argument (`-themePalette CYBER_SLATE`).
    static let storageKey = "themePalette"

    var id: String { rawValue }

    /// A stored identifier, falling back to the default palette for anything unknown.
    static func stored(_ rawValue: String?) -> ThemePalette {
        rawValue.flatMap(ThemePalette.init(rawValue:)) ?? .deckEmerald
    }

    /// The palette the person picked; read on every colour lookup so a change applies at once.
    static var current: ThemePalette {
        stored(UserDefaults.standard.string(forKey: storageKey))
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .deckEmerald: "Deck Emerald"
        case .cyberSlate: "Cyber Slate"
        case .midnightBlue: "Midnight Blue"
        }
    }

    var shortName: LocalizedStringResource {
        switch self {
        case .deckEmerald: "Emerald"
        case .cyberSlate: "Cyber"
        case .midnightBlue: "Midnight"
        }
    }

    var colors: ThemeColors {
        switch self {
        case .deckEmerald:
            ThemeColors(
                background: .init(light: 0xF8FAFC, dark: 0x0B0F17),
                card: .init(light: 0xFFFFFF, dark: 0x1E293B),
                cardVariant: .init(light: 0xF1F5F9, dark: 0x283548),
                border: .init(light: 0xCBD5E1, dark: 0x334155),
                primary: .init(light: 0x047857, dark: 0x10B981),
                secondary: .init(light: 0x0F766E, dark: 0x14B8A6),
                bright: 0x34D399,
                deep: 0x0F172A
            )
        case .cyberSlate:
            ThemeColors(
                background: .init(light: 0xF8FAFC, dark: 0x090D16),
                card: .init(light: 0xFFFFFF, dark: 0x151C2C),
                cardVariant: .init(light: 0xF3F0FF, dark: 0x1E273D),
                border: .init(light: 0xCBD5E1, dark: 0x2E3B54),
                primary: .init(light: 0x6D28D9, dark: 0x8B5CF6),
                secondary: .init(light: 0x0E7490, dark: 0x06B6D4),
                bright: 0xA78BFA,
                deep: 0x151C2C
            )
        case .midnightBlue:
            ThemeColors(
                background: .init(light: 0xF8FAFC, dark: 0x060B16),
                card: .init(light: 0xFFFFFF, dark: 0x0D1B36),
                cardVariant: .init(light: 0xEFF6FF, dark: 0x16294D),
                border: .init(light: 0xCBD5E1, dark: 0x203B6B),
                primary: .init(light: 0x1D4ED8, dark: 0x3B82F6),
                secondary: .init(light: 0x0E7490, dark: 0x06B6D4),
                bright: 0x60A5FA,
                deep: 0x0D1B36
            )
        }
    }
}

/// A colour with a light-mode and a dark-mode value, as 0xRRGGBB.
struct AdaptiveHex: Sendable, Equatable {
    let light: UInt32
    let dark: UInt32

    var color: Color {
        let light = light, dark = dark
        return Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// `overlay` laid over this colour at `amount` opacity, in each appearance.
    func tinted(_ overlay: AdaptiveHex, amount: Double) -> AdaptiveHex {
        AdaptiveHex(light: Self.mix(light, overlay.light, amount), dark: Self.mix(dark, overlay.dark, amount))
    }

    static func mix(_ base: UInt32, _ overlay: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let b = Double((base >> shift) & 0xFF), o = Double((overlay >> shift) & 0xFF)
            return UInt32((b + (o - b) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}

/// The colour roles the app draws with; text roles are shared by all palettes, as on Android.
struct ThemeColors: Sendable, Equatable {
    let background: AdaptiveHex
    let card: AdaptiveHex
    let cardVariant: AdaptiveHex
    let border: AdaptiveHex
    let primary: AdaptiveHex
    let secondary: AdaptiveHex
    /// Accent used on the always-dark hero surface (Android's "bright" tone).
    let bright: UInt32
    /// The always-dark hero surface.
    let deep: UInt32

    static let ink = AdaptiveHex(light: 0x0F172A, dark: 0xF8FAFC)
    static let mutedInk = AdaptiveHex(light: 0x475569, dark: 0x94A3B8)
    static let risk = AdaptiveHex(light: 0xEF4444, dark: 0xEF4444)
    static let tip = AdaptiveHex(light: 0xF59E0B, dark: 0xF59E0B)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// WCAG 2 contrast ratio between two 0xRRGGBB colours (1…21).
enum ContrastRatio {
    static func between(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}
