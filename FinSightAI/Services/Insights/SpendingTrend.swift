import Foundation

/// The one-line spending trend shown on the dashboard and fed to the AI narration.
///
/// It is computed from the ledger (month to date against the same days of last month), not made up.
enum SpendingTrend {
    static let emptyMessage = "Start logging a few expenses to unlock spending pattern analysis."

    /// Relative change below which spending counts as unchanged.
    static let stableBand = 0.05

    static func description(entries: [LedgerEntry], now: Date, calendar: Calendar) -> String {
        let spending = entries.filter(\.countsAsSpending)
        guard !spending.isEmpty else { return emptyMessage }

        let today = calendar.startOfDay(for: now)
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let previousStart = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart)?.start
        else { return emptyMessage }

        let elapsed = calendar.component(.day, from: now)
        let previousDays = calendar.range(of: .day, in: .month, for: previousStart)?.count ?? 30
        guard let previousEnd = calendar.date(byAdding: .day, value: min(elapsed, previousDays), to: previousStart) else {
            return emptyMessage
        }

        let current = spending.filter { $0.date >= monthStart && $0.date < tomorrow }.map(\.amount).sum()
        let previous = spending.filter { $0.date >= previousStart && $0.date < previousEnd }.map(\.amount).sum()

        if previous == 0 {
            return "No spending in the same days last month to compare against yet."
        }
        if current == 0 {
            return "Nothing spent yet this month."
        }
        let change = ((current - previous) / previous).doubleValue
        let percent = abs(change).wholePercent
        if change > stableBand {
            return "Spending is up \(percent)% compared with the same days last month."
        } else if change < -stableBand {
            return "Spending is down \(percent)% compared with the same days last month."
        }
        return "Spending is about the same as the same days last month."
    }
}
