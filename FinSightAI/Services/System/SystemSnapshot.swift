import Foundation
import SwiftData

struct SystemSnapshot: Sendable {
    struct Due: Sendable, Equatable {
        let id: String
        let merchant: String
        let date: Date
    }
    let date: Date
    let currency: String
    let spent: Decimal
    let budget: Decimal
    let topCategory: String?
    let due: [Due]
    let budgets: [BudgetStatusLine]
    let insights: [Insight]
    var progress: Double { budget > 0 ? min(1, max(0, NSDecimalNumber(decimal: spent / budget).doubleValue)) : 0 }
    var spendText: String { spent.formatted(.currency(code: currency)) }

    @MainActor
    static func load(now: Date = .now, container suppliedContainer: ModelContainer? = nil) throws -> SystemSnapshot {
        let container = try suppliedContainer ?? SharedStore.open()
        let context = ModelContext(container)
        let settings = try context.fetch(FetchDescriptor<AppSettings>()).first
        let calendar = settings?.calendar() ?? .current
        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
        let entries = transactions.map(LedgerEntry.init)
        let progress = BudgetCalculator.progress(budgets: try context.fetch(FetchDescriptor<Budget>()), transactions: transactions, month: now, calendar: calendar)
        let ledger = LedgerSnapshot(now: now, calendar: calendar, entries: entries)
        let recurring = try context.fetch(FetchDescriptor<RecurringExpenseRecord>())
        let input = InsightInput(now: now, calendar: calendar, entries: entries,
            budgets: progress.map { BudgetLimit(category: $0.category, limit: $0.limit) },
            recurringMonthlyIncome: IncomeCalculator.recurringMonthlyIncome(sources: try context.fetch(FetchDescriptor<IncomeSource>())),
            reserveBalance: ReserveCalculator.reserve(from: try context.fetch(FetchDescriptor<SavingsGoal>()).map { GoalBalance(name: $0.name, saved: $0.savedAmount) }))
        let insights = InsightVisibility.visible(InsightEngine().insights(for: input), suppressions: try InsightDataLoader.suppressions(in: context), now: now)
        return SystemSnapshot(date: now, currency: settings?.currencyCode ?? CurrencyFormatter.currencyCode,
            spent: ledger.totalSpending(monthsAgo: 0), budget: progress.map(\.limit).sum(),
            topCategory: ledger.categoryTotals(monthsAgo: 0).first?.category.localizedTitle,
            due: upcoming(recurring: recurring, entries: entries, now: now, calendar: calendar),
            budgets: progress.map { BudgetStatusLine(category: $0.category, limit: $0.limit, spent: $0.spent) }, insights: insights)
    }

    #if !WIDGET_EXTENSION
    @MainActor
    static func make(context: AppContext, now: Date = .now) -> SystemSnapshot {
        let calendar = context.settings?.calendar() ?? .current
        let ledger = LedgerSnapshot(now: now, calendar: calendar, entries: context.transactions.map(LedgerEntry.init))
        let budgets = context.budgetProgress.map { BudgetStatusLine(category: $0.category, limit: $0.limit, spent: $0.spent) }
        let due = upcoming(recurring: context.recurringExpenses, entries: context.transactions.map(LedgerEntry.init), now: now, calendar: calendar)
        return SystemSnapshot(date: now, currency: context.settings?.currencyCode ?? "USD",
            spent: ledger.totalSpending(monthsAgo: 0), budget: budgets.map(\.limit).sum(),
            topCategory: ledger.categoryTotals(monthsAgo: 0).first?.category.localizedTitle,
            due: due, budgets: budgets, insights: context.engineInsights)
    }

    #endif

    static func upcoming(recurring: [RecurringExpenseRecord], entries: [LedgerEntry], now: Date, calendar: Calendar) -> [Due] {
        let manual: [Due] = recurring.filter { $0.isActive && $0.category.countsAsSpending }.compactMap { record in
            guard let month = calendar.dateInterval(of: .month, for: now) else { return nil }
            let paid = entries.contains {
                $0.countsAsSpending && $0.date >= month.start && $0.date <= now &&
                DefaultRecurringSummaryService.normalizedMerchantName($0.merchant) == DefaultRecurringSummaryService.normalizedMerchantName(record.merchantName) &&
                record.amount > 0 && abs($0.amount - record.amount) / record.amount <= Decimal(string: "0.1")!
            }
            func due(in month: Date) -> Date? {
                guard let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
                return calendar.date(byAdding: .day, value: min(max(1, record.expectedDay), days.count) - 1, to: month)
            }
            guard var expected = due(in: month.start) else { return nil }
            if paid || expected < calendar.startOfDay(for: now) {
                guard let next = due(in: month.end) else { return nil }
                expected = next
            }
            return Due(id: record.id.uuidString, merchant: record.merchantName, date: expected)
        }
        let manualMerchants = Set(recurring.map { MerchantNormalizer.key(for: $0.merchantName) })
        let detected = RecurringChargeDetector().detect(in: entries, now: now, calendar: calendar).compactMap { charge -> Due? in
            guard !manualMerchants.contains(charge.key), let next = charge.nextExpectedDate,
                  next >= calendar.startOfDay(for: now) else { return nil }
            return Due(id: "detected-" + charge.key, merchant: charge.merchant, date: next)
        }
        return (manual + detected).sorted { $0.date != $1.date ? $0.date < $1.date : $0.id < $1.id }
    }

    static func nextRefresh(after date: Date, calendar: Calendar = .current) -> Date {
        let hour = date.addingTimeInterval(3600)
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? hour
        return min(hour, midnight)
    }
}
