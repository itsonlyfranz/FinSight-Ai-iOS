import SwiftUI

enum AppTheme {
    static let surface = Color("Surface")
    static let surfaceElevated = Color("SurfaceElevated")
    static let surfaceAccent = Color("SurfaceAccent")
    static let cardSurface = Color("CardSurface")
    static let cardTintBudget = Color("CardTintBudget")
    static let cardTintRisk = Color("CardTintRisk")
    static let cardTintGrowth = Color("CardTintGrowth")
    static let primary = Color("Primary")
    static let secondary = Color("Secondary")
    static let ink = Color("Ink")
    static let mutedInk = Color("MutedInk")
    static let divider = Color("Divider")

    static let backgroundGradient = LinearGradient(
        colors: [surface, surfaceAccent, surface],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

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
        static let heroValue = Font.system(size: 40, weight: .bold, design: .rounded)
        static let headline = Font.headline
        static let body = Font.body
        static let caption = Font.caption
    }

    static let cardShadow = primary.opacity(0.12)
    static let cardStroke = divider.opacity(0.8)
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
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
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

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(AppTheme.surfaceAccent.opacity(0.85))
            .frame(maxWidth: width == nil ? .infinity : width, minHeight: height, maxHeight: height)
            .opacity(isAnimating ? 0.7 : 1)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isAnimating)
            .task {
                isAnimating = true
            }
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
    }
}

struct FinSightTypingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.primary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isAnimating ? 0.72 : 1)
                    .opacity(isAnimating ? 0.45 : 1)
                    .animation(
                        .easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: isAnimating
                    )
            }
        }
        .task {
            isAnimating = true
        }
    }
}

struct FinSightStatusLine: View {
    let text: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "clock.arrow.circlepath")
            Text(text)
        }
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.mutedInk)
    }
}
