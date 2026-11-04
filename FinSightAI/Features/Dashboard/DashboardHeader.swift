import SwiftUI

/// The Android greeting row: app name, "Welcome back" with the person's name and role, the
/// theme switcher chip and an initials avatar.
struct DashboardHeader: View {
    @AppStorage(UserProfile.nameKey) private var name = ""
    @AppStorage(UserProfile.roleKey) private var role = ""
    @ScaledMetric(relativeTo: .headline) private var avatarSize: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var profile: UserProfile { UserProfile(name: name, role: role) }

    var body: some View {
        // At accessibility text sizes the greeting gets the full width and the chip and avatar
        // move to their own row, so neither gets squeezed into one character per line.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                greeting
                HStack(spacing: AppTheme.Spacing.sm) {
                    ThemeSwitcherMenu()
                    avatar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
                greeting
                Spacer(minLength: AppTheme.Spacing.xs)
                ThemeSwitcherMenu()
                avatar
            }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "FinSight AI")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.primary)
                .accessibilityAddTraits(.isHeader)
            Group {
                if profile.name.isEmpty {
                    Text("Welcome back")
                } else {
                    Text("Welcome back, \(profile.name)")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.ink)
            if !profile.role.isEmpty {
                Text(profile.role)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(AppTheme.surfaceAccent)
            Circle().stroke(AppTheme.primary.opacity(0.6), lineWidth: 1.5)
            if let initials = profile.initials {
                Text(verbatim: initials)
                    .font(.subheadline.bold())
                    .foregroundStyle(AppTheme.primary)
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(AppTheme.primary)
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .accessibilityHidden(true)
    }
}

/// Android's palette chip: the current theme's dot and short name, opening a menu of all three.
struct ThemeSwitcherMenu: View {
    @AppStorage(ThemePalette.storageKey) private var paletteRawValue = ThemePalette.deckEmerald.rawValue

    private var palette: ThemePalette { ThemePalette.stored(paletteRawValue) }

    var body: some View {
        Menu {
            Picker(selection: $paletteRawValue) {
                ForEach(ThemePalette.allCases) { option in
                    Label {
                        Text(option.displayName)
                    } icon: {
                        Image(systemName: "circle.fill")
                    }
                    .tag(option.rawValue)
                }
            } label: {
                Text("Theme Options")
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(AppTheme.swatch(palette))
                    .frame(width: 8, height: 8)
                Text(palette.shortName)
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.ink)
                Image(systemName: "paintpalette.fill")
                    .imageScale(.small)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.surfaceAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.divider, lineWidth: 1)
            }
        }
        .accessibilityLabel(Text("Theme Options"))
        .accessibilityValue(Text(palette.displayName))
    }
}

/// Android's "Forward Simulator" promo card, opening the Simulator tab.
struct SimulatorQuickActionCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Forward Simulator", systemImage: "chart.line.uptrend.xyaxis")
                .font(AppTheme.Typography.headline)
                .foregroundStyle(AppTheme.onElevated)
            Text("Model compound savings from small habit changes")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.onElevated.opacity(0.85))
            Button(action: action) {
                Label("Open Simulator", systemImage: "arrow.forward")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accentOnElevated)
            .foregroundStyle(AppTheme.surfaceElevated)
            .accessibilityHint(Text("Opens the Simulator tab"))
        }
        .finSightCard(surface: AppTheme.surfaceElevated)
    }
}
