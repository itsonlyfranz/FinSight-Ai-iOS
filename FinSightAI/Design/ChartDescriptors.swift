import Charts
import SwiftUI

/// VoiceOver audio-graph description of the six-month spending bars.
struct MonthlyTrendChartDescriptor: AXChartDescriptorRepresentable {
    let totals: [MonthTotal]

    func makeChartDescriptor() -> AXChartDescriptor {
        let maximum = max(totals.map(\.total.doubleValue).max() ?? 0, 1)
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: String(localized: "Month"),
            categoryOrder: totals.map { MonthFormatter.label(for: $0.monthStart) }
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Spent"),
            range: 0...maximum,
            gridlinePositions: []
        ) { CurrencyFormatter.string(from: $0) }
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Monthly spending"),
            isContinuous: false,
            dataPoints: totals.map {
                AXDataPoint(x: MonthFormatter.label(for: $0.monthStart), y: $0.total.doubleValue)
            }
        )
        return AXChartDescriptor(
            title: String(localized: "6-Month Trend"),
            summary: String(localized: "Total spending for each of the last six months."),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

/// VoiceOver audio-graph description of the category bars.
struct CategoryChartDescriptor: AXChartDescriptorRepresentable {
    let breakdown: [CategorySpend]

    func makeChartDescriptor() -> AXChartDescriptor {
        let maximum = max(breakdown.map(\.amount).max() ?? 0, 1)
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: String(localized: "Category"),
            categoryOrder: breakdown.map(\.category.localizedTitle)
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Amount"),
            range: 0...maximum,
            gridlinePositions: []
        ) { CurrencyFormatter.string(from: $0) }
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Spending by category"),
            isContinuous: false,
            dataPoints: breakdown.map {
                AXDataPoint(x: $0.category.localizedTitle, y: $0.amount, label: PercentFormatter.string(from: $0.percentage))
            }
        )
        return AXChartDescriptor(
            title: String(localized: "Category Breakdown"),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

/// VoiceOver audio-graph description of the simulator's projected balance line.
struct ProjectionChartDescriptor: AXChartDescriptorRepresentable {
    let timeline: [ProjectionPoint]

    func makeChartDescriptor() -> AXChartDescriptor {
        let horizon = Double(max(timeline.last?.month ?? 12, 1))
        let values = timeline.map(\.balance.doubleValue)
        let low = min(values.min() ?? 0, 0), high = max(values.max() ?? 0, 1)
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Month"),
            range: 0...horizon,
            gridlinePositions: [3, 6, 12].filter { $0 <= horizon }
        ) { String(localized: "Month \(Int($0))") }
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Balance"),
            range: low...high,
            gridlinePositions: []
        ) { CurrencyFormatter.string(from: $0) }
        let series = AXDataSeriesDescriptor(
            name: String(localized: "Projected savings"),
            isContinuous: true,
            dataPoints: timeline.map { AXDataPoint(x: Double($0.month), y: $0.balance.doubleValue) }
        )
        return AXChartDescriptor(
            title: String(localized: "Projected savings"),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}

/// VoiceOver audio-graph description of spending against each budget.
struct BudgetChartDescriptor: AXChartDescriptorRepresentable {
    let items: [BudgetProgress]

    func makeChartDescriptor() -> AXChartDescriptor {
        let maximum = max(items.map { max($0.spent, $0.limit).doubleValue }.max() ?? 0, 1)
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: String(localized: "Category"),
            categoryOrder: items.map(\.category.localizedTitle)
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Amount"),
            range: 0...maximum,
            gridlinePositions: []
        ) { CurrencyFormatter.string(from: $0) }
        return AXChartDescriptor(
            title: String(localized: "Spending against budget by category"),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: String(localized: "Spent"),
                    isContinuous: false,
                    dataPoints: items.map { AXDataPoint(x: $0.category.localizedTitle, y: $0.spent.doubleValue) }
                ),
                AXDataSeriesDescriptor(
                    name: String(localized: "Budget"),
                    isContinuous: false,
                    dataPoints: items.map { AXDataPoint(x: $0.category.localizedTitle, y: $0.limit.doubleValue) }
                )
            ]
        )
    }
}

/// VoiceOver audio-graph description of the scenario comparison lines.
struct ScenarioComparisonChartDescriptor: AXChartDescriptorRepresentable {
    let comparison: ScenarioComparison

    func makeChartDescriptor() -> AXChartDescriptor {
        let points = comparison.rows.flatMap { $0.entry.result.timeline.filter { $0.month <= 12 } }
        let values = points.map(\.balance.doubleValue)
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Month"),
            range: 0...12,
            gridlinePositions: [3, 6, 9, 12]
        ) { String(localized: "Month \(Int($0))") }
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Balance"),
            range: min(values.min() ?? 0, 0)...max(values.max() ?? 0, 1),
            gridlinePositions: []
        ) { CurrencyFormatter.string(from: $0) }
        return AXChartDescriptor(
            title: String(localized: "Projected savings by scenario"),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: comparison.rows.map { row in
                AXDataSeriesDescriptor(
                    name: row.label,
                    isContinuous: true,
                    dataPoints: row.entry.result.timeline.filter { $0.month <= 12 }.map {
                        AXDataPoint(x: Double($0.month), y: $0.balance.doubleValue)
                    }
                )
            }
        )
    }
}
