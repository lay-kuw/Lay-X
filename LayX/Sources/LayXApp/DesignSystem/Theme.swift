import SwiftUI

// MARK: - Design tokens (see design/02-design-system.md)

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum LX {
    // 1. Color
    enum C {
        // Backdrop
        static let base = Color(hex: 0x0A0B11)

        // Surfaces
        static let pane = Color(hex: 0x1A1C28, alpha: 0.42)
        static let content = Color(hex: 0x0E0F18, alpha: 0.50)
        static let well = Color.black.opacity(0.22)
        static let code = Color(hex: 0x04050A, alpha: 0.55)
        static let overlay = Color(hex: 0x141622, alpha: 0.94)
        static let mini = Color(hex: 0x12141E, alpha: 0.62)

        // Strokes
        static let edge = Color.white.opacity(0.08)
        static let highlight = Color.white.opacity(0.11)
        static let divider = Color.white.opacity(0.06)
        static let rowLine = Color.white.opacity(0.04)

        // Text
        static let primary = Color(hex: 0xF0F1F6)
        static let body = Color(hex: 0xDADCE6)
        static let secondary = Color(hex: 0xA3A6B6)
        static let tertiary = Color(hex: 0x868A9C)

        // Accent & signal
        static let accent = Color(hex: 0x8FA0FF)
        static let accentText = Color(hex: 0xA9B4FF)
        static let accentTint = Color(hex: 0x8FA0FF, alpha: 0.13)
        static let onGlass = Color(hex: 0xEEF0FF)
        static let liveCyan = Color(hex: 0x7DE3FF)
        static let liveViolet = Color(hex: 0x8F7CFF)
        static let ok = Color(hex: 0x5EE3B0)
        static let warn = Color(hex: 0xF2C46D)
        static let error = Color(hex: 0xFF8A8A)
        static let errorBar = Color(hex: 0xFF6B6B)

        // Syntax
        static let synKeyword = Color(hex: 0xB9A6FF)
        static let synType = Color(hex: 0x86E1F2)
        static let synString = Color(hex: 0xFFB09A)
        static let synNumber = Color(hex: 0xF2D58A)

        // Data viz — fixed categorical order, validated on dark surface
        static let series: [Color] = [Color(hex: 0x1E98B8), Color(hex: 0x7F68DC), Color(hex: 0xB47E24)]

        static let liveGradient = LinearGradient(colors: [LX.C.liveCyan, LX.C.liveViolet], startPoint: .leading, endPoint: .trailing)
    }

    // Glass transparency (Settings → Appearance). t: 0 = solid, 1 = most transparent. Default 0.5.
    enum Glass {
        static let storageKey = "lx.glassTransparency"
        static let defaultValue = 0.5
        /// Multiplier for pane / panel tints. 1.0 at the default.
        static func tintScale(_ t: Double) -> Double { 1.6 - 1.2 * t }
        /// Full-glass mode: the window base over the blurred wallpaper and the pane tints are multiplied by these,
        /// and panes drop their extra frosted material, so the wallpaper clearly shows through everywhere.
        static let fullGlassScale = 0.25
        static let fullGlassPaneScale = 0.3
        static let fullGlassWellScale = 0.45
        static let fullGlassKey = "lx.fullGlass"
        /// Opacity of the dark base over the wallpaper blur.
        static func baseOpacity(_ t: Double) -> Double { 0.97 - 0.17 * t - 0.5 * t * t }
    }

    /// Background glow presets (Settings → Appearance). Top-left = deep glow, bottom-right = faint companion.
    enum Glow: String, CaseIterable, Identifiable {
        case violet, plum, graphite, midnight, teal
        static let storageKey = "lx.glowPreset"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .violet: "Deep Violet"
            case .plum: "Plum"
            case .graphite: "Graphite"
            case .midnight: "Midnight"
            case .teal: "Deep Teal"
            }
        }
        var primary: Color {
            switch self {
            case .violet: Color(hex: 0x3A2E9E, alpha: 0.55)
            case .plum: Color(hex: 0x6A1E55, alpha: 0.55)
            case .graphite: Color(hex: 0x2B2D35, alpha: 0.70)
            case .midnight: Color(hex: 0x1B2F6B, alpha: 0.60)
            case .teal: Color(hex: 0x0E4A4E, alpha: 0.60)
            }
        }
        var secondary: Color {
            switch self {
            case .violet: Color(hex: 0xAA96F0, alpha: 0.16)
            case .plum: Color(hex: 0xE0A0C8, alpha: 0.13)
            case .graphite: Color(hex: 0xB8BAC4, alpha: 0.08)
            case .midnight: Color(hex: 0x9FB4F0, alpha: 0.13)
            case .teal: Color(hex: 0x8FD6D0, alpha: 0.11)
            }
        }
        /// Opaque color used for the picker swatch.
        var swatch: Color {
            switch self {
            case .violet: Color(hex: 0x3A2E9E)
            case .plum: Color(hex: 0x6A1E55)
            case .graphite: Color(hex: 0x2B2D35)
            case .midnight: Color(hex: 0x1B2F6B)
            case .teal: Color(hex: 0x0E4A4E)
            }
        }
    }

    // 3. Spacing (4pt grid)
    enum S {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let header: CGFloat = 48
        static let row: CGFloat = 30
        static let tableRow: CGFloat = 38
        static let control: CGFloat = 28
        static let sidebar: CGFloat = 244
        static let readingWidth: CGFloat = 740
    }

    // 4. Radius
    enum R {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 7
        static let lg: CGFloat = 9
        static let xl: CGFloat = 10
        static let window: CGFloat = 12
    }

    // 2. Typography
    enum F {
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        static let display = LX.F.ui(24, .semibold)
        static let title = LX.F.ui(14, .semibold)
        static let bodyLarge = LX.F.ui(14)
        static let body = LX.F.ui(13)
        static let bodySmall = LX.F.ui(12.5)
        static let caption = LX.F.ui(11.5)
        static let label = LX.F.ui(10.5, .semibold)
        static let monoLarge = LX.F.mono(24, .medium)
        static let code = LX.F.mono(12.5)
        static let monoSmall = LX.F.mono(10.5)
    }

    // 7. Motion
    enum M {
        static let hover = Animation.easeOut(duration: 0.12)
        static let panel = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let mini = Animation.spring(response: 0.28, dampingFraction: 0.9)
        static let streamFlush: TimeInterval = 0.03
    }
}
