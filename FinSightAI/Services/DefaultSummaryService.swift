import Foundation

struct DefaultSummaryService: SummaryService {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func makeMonthlySummary(from transactions: [TransactionRecord], now: Date = .now) -> MonthlySummary {
        let monthInterval = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, end: now)
        let monthlyTransactions = transactions
            .filter { monthInterval.contains($0.date) }
            .sorted(by: { $0.date > $1.date })

        let totalSpent = monthlyTransactions.reduce(0) { $0 + $1.amount }
        let grouped = Dictionary(grouping: monthlyTransactions, by: \.category)
        let categoryBreakdown = grouped
            .map { category, entries in
                let amount = entries.reduce(0) { $0 + $1.amount }
                let share = totalSpent > 0 ? amount / totalSpent : 0
                return CategorySpend(category: category, amount: amount, percentage: share)
            }
            .sorted(by: { $0.amount > $1.amount })

        let averageValue = monthlyTransactions.isEmpty ? 0 : totalSpent / Double(monthlyTransactions.count)
        let topCategory = categoryBreakdown.first?.category
        let topShare = categoryBreakdown.first?.percentage ?? 0

        return MonthlySummary(
            monthStart: monthInterval.start,
            monthLabel: MonthFormatter.label(for: monthInterval.start),
            totalSpent: totalSpent,
            transactionCount: monthlyTransactions.count,
            categoryBreakdown: categoryBreakdown,
            recentTransactions: Array(monthlyTransactions.prefix(5)),
            averageTransactionValue: averageValue,
            topCategory: topCategory,
            topCategoryShare: topShare,
            spendingTrendDescription: spendingTrendDescription(from: monthlyTransactions, now: now)
        )
    }

    func monthlySections(from transactions: [TransactionRecord]) -> [TransactionMonthSection] {
        let grouped = Dictionary(grouping: transactions) {
            calendar.dateComponents([.year, .month], from: $0.date)
        }

        return grouped
            .compactMap { components, values in
                guard let date = calendar.date(from: components) else { return nil }
                return TransactionMonthSection(
                    id: MonthFormatter.sectionID(for: date),
                    title: MonthFormatter.label(for: date),
                    transactions: values.sorted(by: { $0.date > $1.date })
                )
            }
            .sorted { lhs, rhs in lhs.id > rhs.id }
    }

    private func spendingTrendDescription(from transactions: [TransactionRecord], now: Date) -> String {
        guard !transactions.isEmpty else {
            return "Start logging a few expenses to unlock spending pattern analysis."
        }

        let currentWeek = transactions.filter {
            calendar.isDate($0.date, equalTo: now, toGranularity: .weekOfYear)
        }.reduce(0) { $0 + $1.amount }

        let previousWeekDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let previousWeek = transactions.filter {
            calendar.isDate($0.date, equalTo: previousWeekDate, toGranularity: .weekOfYear)
        }.reduce(0) { $0 + $1.amount }

        if previousWeek == 0 {
            return "This month is building its first visible spending baseline."
        }

        let change = (currentWeek - previousWeek) / previousWeek
        if change > 0.15 {
            return "Your current week is trending higher than the week before."
        } else if change < -0.15 {
            return "Your current week is trending lower than the week before."
        } else {
            return "Your weekly spending pace is relatively stable right now."
        }
    }
}
