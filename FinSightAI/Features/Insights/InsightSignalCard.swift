import SwiftUI

/// One deterministic insight: severity badge, headline number, why, and what to do.
struct InsightSignalCard: View {
    let insight: Insight
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
                Image(systemName: insight.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(insight.severity.tint)
                    .frame(minWidth: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    InsightSeverityBadge(severity: insight.severity)
                    Text(insight.title)
                        .font(AppTheme.Typography.headline)
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Snooze for \(AppContext.insightSnoozeDays) days", systemImage: "moon.zzz", action: onSnooze)
                    Button("Dismiss", systemImage: "xmark.circle", role: .destructive, action: onDismiss)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                .accessibilityLabel("Options for \(insight.title)")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(CurrencyFormatter.string(from: insight.impactAmount))
                    .font(AppTheme.Typography.heroValue)
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(insight.impactCaption)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .accessibilityElement(children: .combine)

            Text(insight.summary)
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(insight.suggestedAction)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb.fill")
            }
            .font(.subheadline)
            .foregroundStyle(AppTheme.mutedInk)

            if !insight.evidence.isEmpty {
                DisclosureGroup("Evidence") {
                    VStack(spacing: 6) {
                        ForEach(Array(insight.evidence.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.label)
                                    .foregroundStyle(AppTheme.mutedInk)
                                Spacer(minLength: AppTheme.Spacing.sm)
                                Text(item.value.formatted)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.footnote)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.subheadline)
                .tint(AppTheme.primary)
            }
        }
        .finSightCard(surface: insight.severity.surface)
        .accessibilityElement(children: .contain)
    }
}

struct InsightSeverityBadge: View {
    let severity: Insight.Severity

    var body: some View {
        Text(severity.localizedTitle.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(severity.tint)
            .background(severity.tint.opacity(0.15), in: Capsule())
            .accessibilityLabel("Severity: \(severity.localizedTitle)")
    }
}

extension Insight.Severity {
    var tint: Color {
        switch self {
        case .info: .blue
        case .notice: .yellow.mix(with: .orange, by: 0.4)
        case .warning: .orange
        case .critical: .red
        }
    }

    var surface: Color {
        switch self {
        case .info: AppTheme.cardTintGrowth
        case .notice, .warning: AppTheme.cardTintBudget
        case .critical: AppTheme.cardTintRisk
        }
    }
}

extension Insight.Evidence.Value {
    var formatted: String {
        switch self {
        case .money(let value): CurrencyFormatter.string(from: value)
        case .percent(let value): PercentFormatter.string(from: value)
        case .count(let value): value.formatted()
        case .days(let value): "\(value) day\(value == 1 ? "" : "s")"
        case .months(let value): "\(value.formatted(.number.precision(.fractionLength(0...1)))) months"
        case .number(let value): value.formatted(.number.precision(.fractionLength(0...1)))
        case .date(let value): value.formatted(date: .abbreviated, time: .omitted)
        case .text(let value): value
        }
    }
}
