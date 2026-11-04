import Charts
import SwiftUI

/// The projected savings line with 3/6/12-month markers, a reference rule for each goal that is
/// within reach of the chart, and (optionally) the likely range around the line.
struct ProjectionChart: View {
    let result: SimulationResult
    let showsBand: Bool

    /// Goals whose amount is further above the line than this multiple of its peak stay off the chart,
    /// since drawing them would flatten the projection into the floor.
    private static let goalVisibilityMultiple = 1.5

    private var timeline: [ProjectionPoint] { result.timeline }

    private var peak: Double {
        let top = timeline.map { ($0.upper ?? $0.balance).doubleValue }.max() ?? 0
        return max(top, 1)
    }

    private var visibleGoals: [GoalCountdown] {
        result.goals.filter { $0.remaining > 0 && $0.remaining.doubleValue <= peak * Self.goalVisibilityMultiple }
    }

    private var hiddenGoals: [GoalCountdown] {
        result.goals.filter { $0.remaining > 0 && $0.remaining.doubleValue > peak * Self.goalVisibilityMultiple }
    }

    private var drawsBand: Bool { showsBand && result.hasUncertaintyBand }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            chart
                .frame(height: 240)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Projected savings over \(timeline.last?.month ?? 12) months")
                .accessibilityValue(accessibilitySummary)
            if !hiddenGoals.isEmpty {
                Text(hiddenGoals.map { "\($0.name) (\(money($0.remaining)) to go)" }.joined(separator: ", ")
                    + " is above this chart's range.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
    }

    private var chart: some View {
        let horizon = timeline.last?.month ?? 12
        return Chart {
            if drawsBand {
                ForEach(timeline) { point in
                    if let lower = point.lower, let upper = point.upper {
                        AreaMark(
                            x: .value("Month", point.month),
                            yStart: .value("Low", lower.doubleValue),
                            yEnd: .value("High", upper.doubleValue),
                            series: .value("Series", "Range")
                        )
                        .foregroundStyle(AppTheme.primary.opacity(0.16))
                    }
                }
            }

            ForEach(timeline) { point in
                LineMark(
                    x: .value("Month", point.month),
                    y: .value("Put in", point.contributed.doubleValue),
                    series: .value("Series", "Put in")
                )
                .foregroundStyle(AppTheme.mutedInk)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                LineMark(
                    x: .value("Month", point.month),
                    y: .value("Projected", point.balance.doubleValue),
                    series: .value("Series", "Projected")
                )
                .foregroundStyle(AppTheme.primary)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                .interpolationMethod(.monotone)
            }

            ForEach(result.milestones) { point in
                PointMark(x: .value("Month", point.month), y: .value("Projected", point.balance.doubleValue))
                    .foregroundStyle(AppTheme.primary)
                    .symbolSize(70)
                    .annotation(position: .top, spacing: 4) {
                        VStack(spacing: 0) {
                            Text("\(point.month) mo")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.mutedInk)
                            Text(compact(point.balance))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(AppTheme.ink)
                        }
                    }
            }

            ForEach(visibleGoals) { goal in
                RuleMark(y: .value("Goal", goal.remaining.doubleValue))
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("\(goal.name) · \(compact(goal.remaining))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 3)) { value in
                AxisGridLine().foregroundStyle(AppTheme.divider)
                AxisValueLabel {
                    if let month = value.as(Int.self) { Text("\(month)m") }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(AppTheme.divider)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(compact(Decimal(amount)))
                    }
                }
            }
        }
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: min(horizon, 24))
    }

    private var accessibilitySummary: String {
        let marks = result.milestones.map { "\($0.month) months: \(money($0.balance))" }.joined(separator: ", ")
        let goals = visibleGoals.map { "\($0.name) needs \(money($0.remaining))" }.joined(separator: ", ")
        return [marks, goals].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func money(_ value: Decimal) -> String { CurrencyFormatter.string(from: value) }

    private func compact(_ value: Decimal) -> String {
        value.formatted(.currency(code: CurrencyFormatter.currencyCode).notation(.compactName).precision(.significantDigits(1...3)))
    }
}
