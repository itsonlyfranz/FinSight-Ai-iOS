import Foundation

/// Spending in one category over one month.
struct CategoryTotal: Equatable, Sendable {
    let category: SpendingCategory
    let total: Decimal
}

/// A budgeted category's progress for the current month.
struct BudgetStatusLine: Equatable, Sendable {
    let category: SpendingCategory
    let limit: Decimal
    let spent: Decimal
    var remaining: Decimal { limit - spent }
    var isOver: Bool { spent > limit }
}

/// Immutable, read-only view of the ledger that the AI layer queries.
///
/// Every figure the model quotes comes from here: the tools it can call and the grounding text it is
/// given are both rendered from these queries, so numbers are computed by code, never generated.
struct LedgerSnapshot: Sendable {
    /// Most transactions a search returns, so one tool call can't flood the context window.
    static let maximumSearchResults = 8

    let now: Date
    let calendar: Calendar
    let entries: [LedgerEntry]
    let budgets: [BudgetLimit]

    init(now: Date, calendar: Calendar = .current, entries: [LedgerEntry], budgets: [BudgetLimit] = []) {
        self.now = now
        self.calendar = calendar
        self.entries = entries
        self.budgets = budgets
    }

    static let empty = LedgerSnapshot(now: .now, entries: [])

    func monthStart(monthsAgo: Int) -> Date {
        let current = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let shifted = calendar.date(byAdding: .month, value: -max(0, monthsAgo), to: current) ?? current
        return calendar.dateInterval(of: .month, for: shifted)?.start ?? shifted
    }

    /// Entries dated within the month `monthsAgo` months before the current one (0 = this month).
    /// Nothing dated after today is included.
    func entries(monthsAgo: Int) -> [LedgerEntry] {
        let start = monthStart(monthsAgo: monthsAgo)
        guard let end = calendar.date(byAdding: .month, value: 1, to: start) else { return [] }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return entries.filter { $0.date >= start && $0.date < end && $0.date < tomorrow }
    }

    func totalSpending(monthsAgo: Int) -> Decimal {
        entries(monthsAgo: monthsAgo).filter(\.countsAsSpending).map(\.amount).sum()
    }

    /// Spending per category for a month, largest first. A category filter keeps only that one.
    func categoryTotals(monthsAgo: Int, category: SpendingCategory? = nil) -> [CategoryTotal] {
        let spending = entries(monthsAgo: monthsAgo).filter(\.countsAsSpending)
        let grouped = Dictionary(grouping: spending, by: \.category).map {
            CategoryTotal(category: $0.key, total: $0.value.map(\.amount).sum())
        }
        return grouped
            .filter { category == nil || $0.category == category }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.category.rawValue < $1.category.rawValue }
    }

    /// Transactions whose merchant matches `query` (case- and accent-insensitive), newest first.
    func transactions(matching query: String, limit: Int = LedgerSnapshot.maximumSearchResults) -> [LedgerEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        return entries
            .filter { $0.date < tomorrow && $0.merchant.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.id.uuidString < $1.id.uuidString }
            .prefix(min(max(1, limit), Self.maximumSearchResults))
            .map { $0 }
    }

    /// Progress of the current month against each budget, most over-spent first.
    func budgetStatus(category: SpendingCategory? = nil) -> [BudgetStatusLine] {
        let spent = Dictionary(
            grouping: entries(monthsAgo: 0).filter(\.countsAsSpending),
            by: \.category
        ).mapValues { $0.map(\.amount).sum() }
        return budgets
            .filter { category == nil || $0.category == category }
            .map { BudgetStatusLine(category: $0.category, limit: $0.limit, spent: spent[$0.category] ?? 0) }
            .sorted { $0.remaining != $1.remaining ? $0.remaining < $1.remaining : $0.category.rawValue < $1.category.rawValue }
    }
}

/// Plain-text renderings of ledger queries: what a tool hands back to the model and what the
/// grounding prompt quotes. Amounts are formatted by code, in the user's currency.
enum LedgerText {
    static func money(_ value: Decimal) -> String {
        CurrencyFormatter.string(from: value)
    }

    static func monthLabel(_ ledger: LedgerSnapshot, monthsAgo: Int) -> String {
        MonthFormatter.label(for: ledger.monthStart(monthsAgo: monthsAgo))
    }

    static func categoryTotals(_ ledger: LedgerSnapshot, monthsAgo: Int, category: SpendingCategory?) -> String {
        let label = monthLabel(ledger, monthsAgo: monthsAgo)
        let totals = ledger.categoryTotals(monthsAgo: monthsAgo, category: category)
        guard !totals.isEmpty else {
            return "No spending\(category.map { " in \($0.title)" } ?? "") in \(label)."
        }
        let lines = totals.map { "- \($0.category.title): \(money($0.total))" }
        let total = totals.map(\.total).sum()
        return (["Spending by category, \(label):"] + lines + ["Total: \(money(total))"]).joined(separator: "\n")
    }

    static func transactions(_ ledger: LedgerSnapshot, matching query: String, limit: Int) -> String {
        let found = ledger.transactions(matching: query, limit: limit)
        guard !found.isEmpty else { return "No transactions match \"\(query)\"." }
        let lines = found.map {
            "- \($0.date.formatted(.dateTime.year().month(.abbreviated).day())): \($0.merchant), \(money($0.amount)) (\($0.category.title))"
        }
        return (["Transactions matching \"\(query)\", newest first:"] + lines).joined(separator: "\n")
    }

    static func budgetStatus(_ ledger: LedgerSnapshot, category: SpendingCategory?) -> String {
        let lines = ledger.budgetStatus(category: category)
        guard !lines.isEmpty else { return "No budgets are set\(category.map { " for \($0.title)" } ?? "")." }
        let rendered = lines.map {
            let state = $0.isOver ? "over by \(money(-$0.remaining))" : "\(money($0.remaining)) left"
            return "- \($0.category.title): spent \(money($0.spent)) of \(money($0.limit)) (\(state))"
        }
        return (["Budget status, \(monthLabel(ledger, monthsAgo: 0)):"] + rendered).joined(separator: "\n")
    }
}

extension LedgerSnapshot {
    /// Spending totals for this month and the `NarrationContext.historyMonths` before it, oldest first.
    /// Used to fingerprint the narration so editing history regenerates it.
    var historyTotals: [Decimal] {
        (0...NarrationContext.historyMonths).reversed().map { totalSpending(monthsAgo: $0) }
    }
}
