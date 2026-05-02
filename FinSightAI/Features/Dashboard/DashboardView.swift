import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
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
        .task(id: appContext.monthlySummary.monthLabel) {
            await appContext.loadInsights()
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(appContext.monthlySummary.monthLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)

            Text(CurrencyFormatter.pesoString(from: appContext.monthlySummary.totalSpent))
                .font(AppTheme.Typography.heroValue)
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()

            HStack(spacing: AppTheme.Spacing.sm) {
                metricPill(title: "Transactions", value: "\(appContext.monthlySummary.transactionCount)")
                metricPill(title: "Average", value: CurrencyFormatter.pesoString(from: appContext.monthlySummary.averageTransactionValue))
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                metricPill(title: "Recurring", value: CurrencyFormatter.pesoString(from: appContext.monthlySummary.recurringMonthlySpend))
                metricPill(title: "One-off", value: CurrencyFormatter.pesoString(from: appContext.monthlySummary.oneOffSpent))
            }

            Text(appContext.monthlySummary.spendingTrendDescription)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .finSightCard()
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
            }

            if appContext.recurringSummary.items.isEmpty {
                FinSightEmptyState(
                    title: "No recurring charges set",
                    systemImage: "calendar.badge.clock",
                    message: "Add recurring expenses from Transactions to track fixed monthly spend."
                )
            } else {
                Text(CurrencyFormatter.pesoString(from: appContext.monthlySummary.recurringMonthlySpend))
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
                        Text(CurrencyFormatter.pesoString(from: largest.monthlyAmount))
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
                                Text(amount, format: .currency(code: "PHP").precision(.fractionLength(0)))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxisLabel("Amount", position: .bottomTrailing)
                .frame(height: 240)
            }
        }
        .finSightCard()
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
    }
}

private struct TransactionRow: View {
    let transaction: TransactionRecord

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
                Text(CurrencyFormatter.pesoString(from: transaction.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
    }
}
