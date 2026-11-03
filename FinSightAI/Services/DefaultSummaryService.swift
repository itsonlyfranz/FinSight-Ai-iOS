import Foundation

struct DefaultSummaryService: SummaryService {
    private let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func makeMonthlySummary(
        from transactions: [TransactionRecord],
        recurringSummary: RecurringSummary = .empty,
        now: Date = .now
    ) -> MonthlySummary {
        let monthInterval = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, end: now)
        let monthlyTransactions = transactions
            .filter { monthInterval.contains($0.date) && $0.countsAsSpending }
            .sorted(by: { $0.date > $1.date })

        // Sum exactly in Decimal; only the presentation values below are Doubles.
        let totalSpentExact = monthlyTransactions.map(\.amount).sum()
        let recurringActualSpend = monthlyTransactions
            .filter { recurringSummary.recurringTransactionIDs.contains($0.id) }
            .map(\.amount)
            .sum()
        let totalSpent = totalSpentExact.doubleValue
        let oneOffSpent = max(0, totalSpentExact - recurringActualSpend).doubleValue
        let grouped = Dictionary(grouping: monthlyTransactions, by: \.category)
        let categoryBreakdown = grouped
            .map { category, entries in
                let amount = entries.map(\.amount).sum().doubleValue
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
            recurringMonthlySpend: recurringSummary.totalMonthlySpend,
            recurringTransactionCount: recurringSummary.itemCount,
            oneOffSpent: oneOffSpent,
            largestRecurringMerchant: recurringSummary.largestItem?.merchantName,
            transactionCount: monthlyTransactions.count,
            categoryBreakdown: categoryBreakdown,
            recentTransactions: monthlyTransactions.prefix(5).map(TransactionSnapshot.init),
            averageTransactionValue: averageValue,
            topCategory: topCategory,
            topCategoryShare: topShare,
            spendingTrendDescription: spendingTrendDescription(from: transactions, now: now)
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

    /// Compares the last 7 days with the 7 days before, across all transactions
    /// (not just the current month), so the comparison is meaningful on day 1 of a month.
    private func spendingTrendDescription(from transactions: [TransactionRecord], now: Date) -> String {
        let spending = transactions.filter(\.countsAsSpending)
        guard !spending.isEmpty else {
            return "Start logging a few expenses to unlock spending pattern analysis."
        }

        let today = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: 1, to: today),
              let currentStart = calendar.date(byAdding: .day, value: -6, to: today),
              let previousStart = calendar.date(byAdding: .day, value: -13, to: today) else {
            return "Your weekly spending pace is relatively stable right now."
        }

        let currentWeek = spending
            .filter { $0.date >= currentStart && $0.date < windowEnd }
            .map(\.amount).sum().doubleValue
        let previousWeek = spending
            .filter { $0.date >= previousStart && $0.date < currentStart }
            .map(\.amount).sum().doubleValue

        if previousWeek == 0 {
            return "Not enough spending in the previous 7 days yet to compare against."
        }

        let change = (currentWeek - previousWeek) / previousWeek
        if change > 0.15 {
            return "Your last 7 days are trending higher than the 7 days before."
        } else if change < -0.15 {
            return "Your last 7 days are trending lower than the 7 days before."
        } else {
            return "Your weekly spending pace is relatively stable right now."
        }
    }
}
