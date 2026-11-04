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
            categoryOrder: breakdown.map(\.category.title)
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
                AXDataPoint(x: $0.category.title, y: $0.amount, label: PercentFormatter.string(from: $0.percentage))
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
