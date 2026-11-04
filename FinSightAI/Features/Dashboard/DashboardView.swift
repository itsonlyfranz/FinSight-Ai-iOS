import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppContext.self) private var appContext
    /// Opens another tab; set by `RootTabView`.
    var openSimulator: () -> Void = {}
    var openInsights: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Start of the month the hero, category breakdown and recent activity show.
    @State private var selectedMonth: Date?

    private var month: Date { selectedMonth ?? appContext.monthlySummary.monthStart }
    private var summary: MonthlySummary { appContext.monthlySummary(for: month) }
    private var isCurrentMonth: Bool { Calendar.current.isDate(month, equalTo: .now, toGranularity: .month) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    DashboardHeader(openSettings: openSettings)
                    if appContext.hasNoData {
                        SampleDataCard()
                    }
                    heroCard
                    IncomeGaugeCard()
                    SimulatorQuickActionCard(action: openSimulator)
                    trendCard
                    BudgetOverviewCard()
                    GoalsPreviewCard()
                    recurringSpendCard
                    spendingChartCard
                    recentTransactionsCard
                    insightCard
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Dashboard")
        }
        .sensoryFeedback(.selection, trigger: selectedMonth)
        .task(id: appContext.insightsFingerprint) {
            // Re-runs whenever the underlying data changes; the short delay coalesces rapid edits.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await appContext.loadInsights()
        }
    }

    // MARK: - Month

    private var monthPicker: some View {
        let months = appContext.availableSummaryMonths
        let index = months.firstIndex { Calendar.current.isDate($0, equalTo: month, toGranularity: .month) }
        return HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                if let index, index + 1 < months.count { selectedMonth = months[index + 1] }
            } label: {
                Label("Previous month", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(index.map { $0 + 1 >= months.count } ?? true)

            Menu {
                Picker("Month", selection: Binding(get: { month }, set: { selectedMonth = $0 })) {
                    ForEach(months, id: \.self) { month in
                        Text(MonthFormatter.label(for: month)).tag(month)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(isCurrentMonth ? String(localized: "This month's outflow") : summary.monthLabel)
                        .textCase(.uppercase)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)
            }
            .accessibilityLabel(Text("Month"))
            .accessibilityValue(Text(summary.monthLabel))

            Button {
                if let index, index > 0 { selectedMonth = months[index - 1] }
            } label: {
                Label("Next month", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled((index ?? 0) == 0)
        }
        .buttonStyle(.borderless)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            monthPicker

            Text(CurrencyFormatter.string(from: summary.totalSpent))
                .font(AppTheme.Typography.heroValue)
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel(Text("Spent in \(summary.monthLabel)"))
                .accessibilityValue(CurrencyFormatter.string(from: summary.totalSpent))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) { heroPills }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) { heroPills }
            }

            if isCurrentMonth {
                Text(summary.spendingTrend)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var heroPills: some View {
        metricPill(title: "Transactions", value: "\(summary.transactionCount)")
        metricPill(title: "Average", value: CurrencyFormatter.string(from: summary.averageTransactionValue))
        metricPill(title: "One-off", value: CurrencyFormatter.string(from: summary.oneOffSpent))
    }

    // MARK: - Six-month trend

    private var trendCard: some View {
        let totals = appContext.sixMonthTrend(endingAt: month)
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Label("6-Month Trend", systemImage: "chart.bar.fill")
                .font(AppTheme.Typography.headline)
            if totals.allSatisfy({ $0.total == 0 }) {
                FinSightEmptyState(
                    title: "No history yet",
                    systemImage: "chart.bar",
                    message: "Monthly totals appear here as you log spending."
                )
            } else {
                Chart(totals) { item in
                    BarMark(
                        x: .value("Month", item.monthStart, unit: .month),
                        y: .value("Spent", item.total.doubleValue)
                    )
                    .foregroundStyle(Calendar.current.isDate(item.monthStart, equalTo: month, toGranularity: .month)
                                     ? AppTheme.primary : AppTheme.primary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(AppTheme.divider)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount, format: .currency(code: CurrencyFormatter.currencyCode).notation(.compactName))
                            }
                        }
                    }
                }
                .frame(minHeight: chartHeight)
                .accessibilityChartDescriptor(MonthlyTrendChartDescriptor(totals: totals))
            }
        }
        .finSightCard()
    }

    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 180
    @ScaledMetric(relativeTo: .subheadline) private var recurringIconSize: CGFloat = 32

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
                            .accessibilityHidden(true)
                            .frame(width: recurringIconSize, height: recurringIconSize)
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
            HStack(alignment: .firstTextBaseline) {
                Text("Category Breakdown")
                    .font(AppTheme.Typography.headline)
                Spacer()
                Text("\(summary.categoryBreakdown.count) categories")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }

            if summary.categoryBreakdown.isEmpty {
                FinSightEmptyState(
                    title: "No spend yet",
                    systemImage: "chart.bar.xaxis",
                    message: "Add transactions to see where your budget is going."
                )
            } else {
                Chart(summary.categoryBreakdown) { item in
                    BarMark(
                        x: .value("Amount", item.amount),
                        y: .value("Category", item.category.localizedTitle)
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
                .frame(minHeight: categoryChartHeight)
                .accessibilityChartDescriptor(CategoryChartDescriptor(breakdown: summary.categoryBreakdown))
            }
        }
        .finSightCard()
    }

    @ScaledMetric(relativeTo: .body) private var categoryChartHeight: CGFloat = 240

    private var recentTransactionsCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Recent Activity")
                .font(AppTheme.Typography.headline)

            if summary.recentTransactions.isEmpty {
                FinSightEmptyState(
                    title: "No recent transactions",
                    systemImage: "list.bullet.rectangle",
                    message: "Once you log spending, the latest activity will show up here."
                )
            } else {
                ForEach(summary.recentTransactions) { transaction in
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
                Button("View All", action: openInsights)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint(Text("Opens the Insights tab"))
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
                        FinSightStatusLine("Streaming latest insight…")
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
            case .modelUnavailable(let reason):
                insightFallback(note: reason.message, systemImage: reason.systemImage)
            case .unavailable(let message), .failure(let message):
                insightFallback(note: message, systemImage: "exclamationmark.triangle")
            }
        }
        .finSightCard(surface: AppTheme.cardTintBudget)
    }

    /// Without the model, the day's insight is the top deterministic one, with the reason AI is off.
    @ViewBuilder
    private func insightFallback(note: String, systemImage: String) -> some View {
        if let insight = appContext.engineInsights.first {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(insight.title)
                    .font(AppTheme.Typography.headline)
                Text(insight.summary)
                    .font(AppTheme.Typography.body)
            }
        }
        Label(note, systemImage: systemImage)
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.mutedInk)
    }

    private func metricPill(title: LocalizedStringKey, value: String) -> some View {
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
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 38

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: transaction.category.symbolName)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
                .frame(width: iconSize, height: iconSize)
                .background(transaction.category.tint, in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.icon, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchantName.isEmpty ? transaction.category.localizedTitle : transaction.merchantName)
                    .font(.subheadline.weight(.semibold))
                Text(transaction.note.isEmpty ? String(localized: "No note") : transaction.note)
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
