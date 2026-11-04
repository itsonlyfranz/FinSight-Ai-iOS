import SwiftUI

enum AppTheme {
    private static var palette: ThemeColors { ThemePalette.current.colors }

    static var surface: Color { palette.background.color }
    /// Always-dark hero surface; draw on it with `onElevated` and `accentOnElevated`.
    static var surfaceElevated: Color { Color(uiColor: UIColor(hex: palette.deep)) }
    static var surfaceAccent: Color { palette.cardVariant.color }
    static var cardSurface: Color { palette.card.color }
    static var cardTintBudget: Color { palette.card.tinted(palette.primary, amount: 0.08).color }
    static var cardTintRisk: Color { palette.card.tinted(ThemeColors.risk, amount: 0.08).color }
    static var cardTintGrowth: Color { palette.card.tinted(AdaptiveHex(light: 0x10B981, dark: 0x10B981), amount: 0.08).color }
    static var primary: Color { palette.primary.color }
    static var secondary: Color { palette.secondary.color }
    static var ink: Color { ThemeColors.ink.color }
    static var mutedInk: Color { ThemeColors.mutedInk.color }
    static var divider: Color { palette.border.color }
    static let onElevated = Color(uiColor: UIColor(hex: 0xF8FAFC))
    static var accentOnElevated: Color { Color(uiColor: UIColor(hex: palette.bright)) }
    /// The palette's swatch, as shown in the theme switcher.
    static func swatch(_ palette: ThemePalette) -> Color { Color(uiColor: UIColor(hex: palette.colors.bright)) }

    static var backgroundGradient: LinearGradient {
        LinearGradient(colors: [surface, surfaceAccent, surface], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    enum Spacing {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum CornerRadius {
        static let card: CGFloat = 28
        static let pill: CGFloat = 18
        static let icon: CGFloat = 10
    }

    enum Typography {
        /// Scales with Dynamic Type (a fixed point size would ignore the user's text size).
        static let heroValue = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
    }

    static var cardShadow: Color { primary.opacity(0.12) }
    static var cardStroke: Color { divider.opacity(0.8) }
}

private struct FinSightCardModifier: ViewModifier {
    let surface: Color

    func body(content: Content) -> some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.CornerRadius.card, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            }
            .shadow(color: AppTheme.cardShadow, radius: 12, y: 6)
    }
}

extension View {
    func finSightCard(surface: Color = AppTheme.cardSurface) -> some View {
        modifier(FinSightCardModifier(surface: surface))
    }
}

struct FinSightEmptyState: View {
    let title: LocalizedStringResource
    let systemImage: String
    let message: LocalizedStringResource

    var body: some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { Image(systemName: systemImage) }
        } description: {
            Text(message)
        }
        .foregroundStyle(AppTheme.mutedInk)
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct FinSightSkeletonBlock: View {
    let width: CGFloat?
    let height: CGFloat
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Placeholder lines grow with the text size they stand in for.
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.surfaceAccent.opacity(0.85))
            .frame(maxWidth: width.map { $0 * scale } ?? .infinity, minHeight: height * scale, maxHeight: height * scale)
            .opacity(isAnimating ? 0.7 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isAnimating)
            .task {
                isAnimating = !reduceMotion
            }
            .accessibilityHidden(true)
    }
}

struct FinSightInsightSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            FinSightSkeletonBlock(width: 120, height: 16)
            FinSightSkeletonBlock(width: nil, height: 18)
            FinSightSkeletonBlock(width: nil, height: 18)
            FinSightSkeletonBlock(width: 180, height: 18)
        }
        .finSightCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
    }
}

struct FinSightTypingIndicator: View {
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.primary)
                    .frame(width: dot, height: dot)
                    .scaleEffect(isAnimating ? 0.72 : 1)
                    .opacity(isAnimating ? 0.45 : 1)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .task {
            isAnimating = !reduceMotion
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Writing"))
    }
}

struct FinSightStatusLine: View {
    let text: String

    init(text: String) { self.text = text }
    init(_ resource: LocalizedStringResource) { self.text = String(localized: resource) }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .accessibilityHidden(true)
            Text(text)
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.mutedInk)
    }
}

/// An animation that is skipped when Reduce Motion is on.
private struct MotionSafeAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    func motionSafeAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionSafeAnimation(animation: animation, value: value))
    }
}
