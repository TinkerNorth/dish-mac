import SwiftUI

/// Color palette lifted verbatim from `dish-android/res/values/colors.xml` so
/// both clients look identical side-by-side.
enum DishTheme {
    static let background    = Color(hex: 0x0D0F12)
    static let surface       = Color(hex: 0x161A1F)
    static let surfaceDim    = Color(hex: 0x111417)
    static let primary       = Color(hex: 0xFFC107) // amber
    static let primaryDark   = Color(hex: 0xA65F1E)
    static let onPrimary     = Color(hex: 0x0D0F12)
    static let onSurface     = Color(hex: 0xEAEAEA)
    static let muted         = Color(hex: 0x6B7280)
    static let outline       = Color(hex: 0x222831)
    static let success       = Color(hex: 0x22C55E)
    static let error         = Color(hex: 0xE74C3C)
    static let warning       = Color(hex: 0xF59E0B)
    /// primary at ~12% alpha — matches colorCardStroke (#1FFFC107).
    static let cardStroke    = Color(hex: 0xFFC107, alpha: 0.12)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double((hex      ) & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Section label style (monospace, yellow, spaced) — matches the
/// `TextView` with `textColor="@color/colorPrimary"` + `fontFamily="monospace"`
/// + `letterSpacing="0.12"` used throughout `activity_main.xml`.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .tracking(1.3)
            .foregroundColor(DishTheme.primary)
    }
}

/// The small coloured dot used in the status row.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Outlined button styled to match `Widget.Dish.Button.Outlined`.
struct DishOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DishTheme.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DishTheme.primary, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(configuration.isPressed
                                  ? DishTheme.primary.opacity(0.12)
                                  : Color.clear)
                    )
            )
    }
}
