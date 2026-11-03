import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if appContext.hasNoData {
                        SampleDataCard()
                    }
                    heroCard
                    recurringSpendCard
                    spendingChartCard
                    recentTransactionsCard
                    insightCard
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("FinSight AI")
        }
        .task(id: appContext.insightsFingerprint) {
            // Re-runs whenever the underlying data changes; the short delay coalesces rapid edits.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await appContext.loadInsights()
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(appContext.monthlySummary.monthLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)

            Text(CurrencyFormatter.string(from: appContext.monthlySummary.totalSpent))
                .font(AppTheme.Typography.heroValue)
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityLabel("Spent this month")
                .accessibilityValue(CurrencyFormatter.string(from: appContext.monthlySummary.totalSpent))

            HStack(spacing: AppTheme.Spacing.sm) {
                metricPill(title: "Transactions", value: "\(appContext.monthlySummary.transactionCount)")
                metricPill(title: "Average", value: CurrencyFormatter.string(from: appContext.monthlySummary.averageTransactionValue))
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                metricPill(title: "Recurring", value: CurrencyFormatter.string(from: appContext.monthlySummary.recurringMonthlySpend))
                metricPill(title: "One-off", value: CurrencyFormatter.string(from: appContext.monthlySummary.oneOffSpent))
            }

            Text(appContext.monthlySummary.spendingTrendDescription)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .finSightCard()
        .accessibilityElement(children: .contain)
    }

    private var recurringSpendCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Label("Recurring Spend", systemImage: "repeat.circle.fill")
                    .font(AppTheme.Typography.headline)
                Spacer()
                Text("\(appContext.monthlySummary.recurringTransactionCount)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppTheme.primary)
                    .accessibilityLabel("\(appContext.monthlySummary.recurringTransactionCount) recurring charges")
            }

            if appContext.recurringSummary.spendingItems.isEmpty {
                FinSightEmptyState(
                    title: "No recurring charges set",
                    systemImage: "calendar.badge.clock",
                    message: "Add recurring expenses from Transactions to track fixed monthly spend."
                )
            } else {
                Text(CurrencyFormatter.string(from: appContext.monthlySummary.recurringMonthlySpend))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .monospacedDigit()
                if let largest = appContext.recurringSummary.largestItem {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: largest.category.symbolName)
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(largest.category.tint, in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.icon, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(largest.merchantName)
                                .font(.subheadline.weight(.semibold))
                            Text("Largest recurring charge")
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                        Spacer()
                        Text(CurrencyFormatter.string(from: largest.monthlyAmount))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .finSightCard(surface: AppTheme.cardTintGrowth)
    }

    private var spendingChartCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Category Breakdown")
                .font(AppTheme.Typography.headline)

            if appContext.monthlySummary.categoryBreakdown.isEmpty {
                FinSightEmptyState(
                    title: "No spend yet",
                    systemImage: "chart.bar.xaxis",
                    message: "Add transactions to see where your budget is going."
                )
            } else {
                Chart(appContext.monthlySummary.categoryBreakdown) { item in
                    BarMark(
                        x: .value("Amount", item.amount),
                        y: .value("Category", item.category.title)
                    )
                    .foregroundStyle(item.category.tint.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(AppTheme.divider)
                        AxisTick()
                            .foregroundStyle(AppTheme.divider)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount, format: .currency(code: CurrencyFormatter.currencyCode).precision(.fractionLength(0)))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxisLabel("Amount", position: .bottomTrailing)
                .frame(height: 240)
                .accessibilityLabel("Spending by category")
                .accessibilityValue(chartAccessibilitySummary)
            }
        }
        .finSightCard()
    }

    private var chartAccessibilitySummary: String {
        appContext.monthlySummary.categoryBreakdown
            .map { "\($0.category.title), \(CurrencyFormatter.string(from: $0.amount)), \(PercentFormatter.string(from: $0.percentage))" }
            .joined(separator: "; ")
    }

    private var recentTransactionsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Recent Activity")
                .font(AppTheme.Typography.headline)

            if appContext.monthlySummary.recentTransactions.isEmpty {
                FinSightEmptyState(
                    title: "No recent transactions",
                    systemImage: "list.bullet.rectangle",
                    message: "Once you log spending, the latest activity will show up here."
                )
            } else {
                ForEach(appContext.monthlySummary.recentTransactions) { transaction in
                    TransactionRow(transaction: transaction)
                }
            }
        }
        .finSightCard()
    }

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Label("AI Insight of the Day", systemImage: "sparkles")
                    .font(AppTheme.Typography.headline)
                Spacer()
            }

            switch appContext.insightState {
            case .empty:
                Text("Add a few expenses to unlock AI insights.")
                    .foregroundStyle(AppTheme.mutedInk)
                    .font(AppTheme.Typography.body)
            case .idle, .loading:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    FinSightSkeletonBlock(width: 180, height: 16)
                    FinSightSkeletonBlock(width: nil, height: 18)
                    FinSightSkeletonBlock(width: nil, height: 18)
                }
            case .available(let content):
                if let card = content.value.first(where: { $0.kind == .budgeting }) {
                    FinSightMarkdownView(markdown: card.markdown, style: .dashboardPreview)
                        .font(AppTheme.Typography.body)
                    if content.isRefreshing {
                        FinSightStatusLine(text: "Streaming latest insight...")
                    }
                    FinSightStatusLine(text: RelativeTimestampFormatter.updatedString(for: content.lastUpdated))
                    if let statusMessage = content.statusMessage {
                        Text(statusMessage)
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.mutedInk)
                    }
                } else {
                    Text("No insight available.")
                        .foregroundStyle(AppTheme.ink)
                        .font(AppTheme.Typography.body)
                }
            case .unavailable(let message), .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard(surface: AppTheme.cardTintBudget)
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.mutedInk)
            Text(value)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(AppTheme.surfaceAccent, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct TransactionRow: View {
    let transaction: TransactionSnapshot

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: transaction.category.symbolName)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(transaction.category.tint, in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.icon, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName.isEmpty ? transaction.category.title : transaction.merchantName)
                    .font(.subheadline.weight(.semibold))
                Text(transaction.note.isEmpty ? "No note" : transaction.note)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(CurrencyFormatter.string(from: transaction.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
