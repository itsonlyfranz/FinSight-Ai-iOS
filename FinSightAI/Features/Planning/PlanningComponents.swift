import Charts
import SwiftUI

extension BudgetStatus {
    var tint: Color {
        switch self {
        case .onTrack: .green
        case .nearLimit: .orange
        case .overBudget: .red
        }
    }
}

extension BudgetProgress {
    /// Spoken summary used by accessibility labels.
    var accessibilitySummary: String {
        let used = PercentFormatter.string(from: fractionUsed)
        let left = remaining >= 0
            ? "\(CurrencyFormatter.string(from: remaining)) left"
            : "\(CurrencyFormatter.string(from: -remaining)) over"
        return "\(category.title) budget, spent \(CurrencyFormatter.string(from: spent)) of \(CurrencyFormatter.string(from: limit)), \(used) used, \(left), \(status.title)"
    }
}

/// Spending against budget per category: a bar for what was spent and a dark tick at the limit.
struct BudgetBarChart: View {
    let items: [BudgetProgress]

    var body: some View {
        let widest = items.map { max($0.limit, $0.spent) }.max() ?? 0
        let tick = max(widest.doubleValue * 0.006, 0.01)

        Chart(items) { item in
            BarMark(
                x: .value("Spent", item.spent.doubleValue),
                y: .value("Category", item.category.title)
            )
            .foregroundStyle(item.status.tint.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            BarMark(
                xStart: .value("Budget start", max(0, item.limit.doubleValue - tick)),
                xEnd: .value("Budget end", item.limit.doubleValue + tick),
                y: .value("Category", item.category.title),
                height: .fixed(26)
            )
            .foregroundStyle(AppTheme.ink)
            .accessibilityLabel("\(item.category.title) budget")
            .accessibilityValue(CurrencyFormatter.string(from: item.limit))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(AppTheme.divider)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount, format: .currency(code: CurrencyFormatter.currencyCode).precision(.fractionLength(0)))
                    }
                }
            }
        }
        .frame(height: CGFloat(items.count) * 46 + 36)
        .accessibilityLabel("Spending against budget by category")
        .accessibilityValue(items.map(\.accessibilitySummary).joined(separator: "; "))
    }
}

/// Reusable label/progress/amount row for a budget.
struct BudgetProgressRow: View {
    let progress: BudgetProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(progress.category.title, systemImage: progress.category.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Spacer()
                Label(progress.status.title, systemImage: progress.status.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(progress.status.tint)
                    .labelStyle(.titleAndIcon)
            }
            ProgressView(value: progress.progressValue)
                .tint(progress.status.tint)
            HStack {
                Text("\(CurrencyFormatter.string(from: progress.spent)) of \(CurrencyFormatter.string(from: progress.limit))")
                Spacer()
                Text(progress.remaining >= 0
                     ? "\(CurrencyFormatter.string(from: progress.remaining)) left"
                     : "\(CurrencyFormatter.string(from: -progress.remaining)) over")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.mutedInk)
            if progress.carriedOver > 0 {
                Text("Includes \(CurrencyFormatter.string(from: progress.carriedOver)) carried over")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.accessibilitySummary)
    }
}

/// Goal summary with progress and the months-to-reach / funded-by estimate.
struct SavingsGoalRow: View {
    let goal: SavingsGoal
    let projection: GoalProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.name.isEmpty ? "Goal" : goal.name)
                    .font(.headline)
                Spacer()
                Text(PercentFormatter.string(from: goal.progress))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.primary)
            }
            ProgressView(value: goal.progress)
                .tint(goal.isReached ? .green : AppTheme.primary)
            Text("\(CurrencyFormatter.string(from: goal.savedAmount)) of \(CurrencyFormatter.string(from: goal.targetAmount))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.mutedInk)
            Text(outlookText)
                .font(.caption.weight(.medium))
                .foregroundStyle(projection.isBehindTargetDate(goal.targetDate) ? .orange : AppTheme.ink)
            if let line = targetDateText {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var outlookText: String {
        switch projection.outlook {
        case .reached:
            return "Goal reached"
        case .noPace:
            return "Add income or a contribution to estimate a funding date"
        case .onPace(let months, let date):
            let duration = months == 1 ? "1 month" : "\(months) months"
            return "About \(duration) to go, funded by \(date.formatted(.dateTime.month(.wide).year()))"
        }
    }

    private var targetDateText: String? {
        guard let targetDate = goal.targetDate else { return nil }
        var text = "Target \(targetDate.formatted(.dateTime.month(.abbreviated).day().year()))"
        if let required = projection.requiredMonthly {
            text += " — needs \(CurrencyFormatter.string(from: required)) a month"
        }
        if projection.isBehindTargetDate(targetDate) {
            text += " (behind pace)"
        }
        return text
    }

    private var accessibilityText: String {
        var parts = [
            "\(goal.name), \(PercentFormatter.string(from: goal.progress)) saved",
            "\(CurrencyFormatter.string(from: goal.savedAmount)) of \(CurrencyFormatter.string(from: goal.targetAmount))",
            outlookText
        ]
        if let targetDateText { parts.append(targetDateText) }
        return parts.joined(separator: ", ")
    }
}

extension String {
    var parsedAmount: Decimal? { AmountParser.parse(self) }
}
