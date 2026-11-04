import SwiftUI

/// "% of income spent / buffer remaining" for the current month.
struct IncomeGaugeCard: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        let gauge = appContext.incomeGauge
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Income & Buffer", systemImage: "gauge.with.dots.needle.67percent")
                .font(AppTheme.Typography.headline)

            if gauge.hasIncome {
                Gauge(value: gauge.gaugeValue) {
                    Text("Income spent")
                } currentValueLabel: {
                    Text(PercentFormatter.string(from: gauge.fractionSpent))
                        .font(.title2.weight(.bold).monospacedDigit())
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(Gradient(colors: [.green, .yellow, .orange, .red]))

                HStack {
                    metric("Income", CurrencyFormatter.string(from: gauge.income))
                    Spacer()
                    metric("Spent", CurrencyFormatter.string(from: gauge.spent))
                    Spacer()
                    metric(
                        gauge.isOverspent ? LocalizedStringKey("Over income") : LocalizedStringKey("Buffer left"),
                        CurrencyFormatter.string(from: abs(gauge.buffer)),
                        tint: gauge.isOverspent ? .red : .green
                    )
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("Add your monthly income to see how much of it you've spent and how much buffer is left.")
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(AppTheme.mutedInk)
                NavigationLink {
                    IncomeSourcesView()
                } label: {
                    Label("Add income", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
            }
        }
        .finSightCard(surface: AppTheme.cardTintBudget)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText(gauge))
    }

    private func metric(_ title: LocalizedStringKey, _ value: String, tint: Color = AppTheme.ink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(AppTheme.mutedInk)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(tint)
        }
    }

    private func accessibilityText(_ gauge: IncomeGauge) -> String {
        guard gauge.hasIncome else { return "Income and buffer. No income set." }
        let buffer = gauge.isOverspent
            ? "\(CurrencyFormatter.string(from: -gauge.buffer)) over income"
            : "\(CurrencyFormatter.string(from: gauge.buffer)) buffer remaining"
        return "Income and buffer. \(PercentFormatter.string(from: gauge.fractionSpent)) of income spent, \(buffer)."
    }
}

/// Budget progress for the month, with a link to the editor.
struct BudgetOverviewCard: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Label("Budgets", systemImage: "target")
                    .font(AppTheme.Typography.headline)
                Spacer()
                NavigationLink("Edit") { BudgetsView() }
                    .font(.subheadline.weight(.semibold))
            }

            if appContext.budgetProgress.isEmpty {
                Text("Set a monthly limit for the categories you want to keep an eye on.")
                    .foregroundStyle(AppTheme.mutedInk)
                NavigationLink {
                    BudgetsView()
                } label: {
                    Label("Set budgets", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
            } else {
                BudgetBarChart(items: appContext.budgetProgress)
                Text("Bars show spending this month; the dark tick marks each budget.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
    }
}

/// The first few goals with progress, linking to the full list.
struct GoalsPreviewCard: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Label("Savings Goals", systemImage: "flag.checkered")
                    .font(AppTheme.Typography.headline)
                Spacer()
                NavigationLink("See all") { SavingsGoalsView() }
                    .font(.subheadline.weight(.semibold))
            }

            if appContext.savingsGoals.isEmpty {
                Text("Create a goal to track progress and see when it will be funded.")
                    .foregroundStyle(AppTheme.mutedInk)
                NavigationLink {
                    SavingsGoalsView()
                } label: {
                    Label("Add a goal", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
            } else {
                ForEach(appContext.savingsGoals.prefix(3)) { goal in
                    SavingsGoalRow(goal: goal, projection: appContext.goalProjection(for: goal))
                }
            }
        }
        .finSightCard(surface: AppTheme.cardTintGrowth)
    }
}
