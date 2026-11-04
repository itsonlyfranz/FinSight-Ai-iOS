import Foundation

/// Spending per calendar month, for the dashboard month picker and the six-month trend chart.
struct MonthTotal: Identifiable, Equatable, Sendable {
    let monthStart: Date
    let total: Decimal

    var id: Date { monthStart }
}

enum MonthlyTrend {
    /// `count` consecutive months ending with the month containing `endingAt`, oldest first.
    /// Months without spending are included as zero so the chart never skips a month.
    static func totals(
        entries: [LedgerEntry],
        endingAt: Date,
        count: Int = 6,
        calendar: Calendar = .current
    ) -> [MonthTotal] {
        guard count > 0, let lastMonth = calendar.dateInterval(of: .month, for: endingAt)?.start else { return [] }
        let months: [Date] = (0..<count).reversed().compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: lastMonth)
        }
        var sums: [Date: Decimal] = [:]
        for entry in entries where entry.countsAsSpending {
            guard let month = calendar.dateInterval(of: .month, for: entry.date)?.start else { continue }
            sums[month, default: 0] += entry.amount
        }
        return months.map { MonthTotal(monthStart: $0, total: sums[$0] ?? 0) }
    }

    /// Month starts the picker offers: from the earliest entry (at most `limit` months back) to
    /// the month containing `now`, newest first. Always contains the current month.
    static func availableMonths(
        entries: [LedgerEntry],
        now: Date,
        limit: Int = 24,
        calendar: Calendar = .current
    ) -> [Date] {
        guard let current = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let earliest = entries.map(\.date).min().flatMap { calendar.dateInterval(of: .month, for: $0)?.start } ?? current
        let span = calendar.dateComponents([.month], from: earliest, to: current).month ?? 0
        let months = min(max(span, 0), limit - 1)
        return (0...months).compactMap { calendar.date(byAdding: .month, value: -$0, to: current) }
    }
}
