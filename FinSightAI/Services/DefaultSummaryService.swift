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
            .filter { monthInterval.containsExcludingEnd($0.date) && $0.countsAsSpending }
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
            spendingTrendDescription: SpendingTrend.description(
                entries: transactions.map(LedgerEntry.init),
                now: now,
                calendar: calendar
            )
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
}
