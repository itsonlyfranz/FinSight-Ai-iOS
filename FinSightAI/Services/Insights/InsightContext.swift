import Foundation

/// Precomputed calendar facts and month buckets shared by the detectors.
///
/// All day arithmetic goes through `Calendar` (start-of-day, `dateInterval(of:)`, `range(of:)`),
/// never through 86,400-second offsets, so DST changes and month lengths cannot skew results.
struct InsightContext {
    let calendar: Calendar
    let now: Date
    let configuration: InsightEngineConfiguration
    let budgets: [BudgetLimit]
    let recurringMonthlyIncome: Decimal
    let reserveBalance: Decimal

    let today: Date
    /// First month that has any data; baselines never reach before it.
    let firstMonthStart: Date?
    let monthStart: Date
    let daysInMonth: Int
    /// Calendar day of the month `now` falls on (1-based). Today counts as elapsed.
    let elapsedDays: Int
    /// Entries up to and including today.
    let entries: [LedgerEntry]
    let entriesByMonth: [Date: [LedgerEntry]]

    init(_ input: InsightInput) {
        calendar = input.calendar
        now = input.now
        configuration = input.configuration
        budgets = input.budgets
        recurringMonthlyIncome = input.recurringMonthlyIncome
        reserveBalance = input.reserveBalance

        let calendar = input.calendar
        today = calendar.startOfDay(for: input.now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? input.now
        entries = input.entries.filter { $0.date < tomorrow }
        entriesByMonth = Dictionary(grouping: entries) { Self.monthStart(of: $0.date, calendar: calendar) }
        monthStart = Self.monthStart(of: input.now, calendar: calendar)
        daysInMonth = calendar.range(of: .day, in: .month, for: input.now)?.count ?? 30
        elapsedDays = calendar.component(.day, from: input.now)
        firstMonthStart = entries.map(\.date).min().map { Self.monthStart(of: $0, calendar: calendar) }
    }

    static func monthStart(of date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Start of the month `offset` months from the current one (negative = past).
    func month(_ offset: Int) -> Date {
        guard let shifted = calendar.date(byAdding: .month, value: offset, to: monthStart) else { return monthStart }
        return Self.monthStart(of: shifted, calendar: calendar)
    }

    func entries(inMonth start: Date) -> [LedgerEntry] { entriesByMonth[start] ?? [] }

    func spending(inMonth start: Date) -> [LedgerEntry] { entries(inMonth: start).filter(\.countsAsSpending) }

    var currentSpending: [LedgerEntry] { spending(inMonth: monthStart) }

    var daysLeft: Int { max(0, daysInMonth - elapsedDays) }

    /// Complete months before the current one that can serve as a baseline, newest first, limited
    /// to `count` and never reaching before the first month with data.
    func completeMonths(limit count: Int) -> [Date] {
        guard let firstMonthStart else { return [] }
        return (1...max(1, count)).compactMap { offset in
            let start = month(-offset)
            return start >= firstMonthStart ? start : nil
        }
    }

    func periodKey(_ start: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: start)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func total(_ entries: [LedgerEntry]) -> Decimal { entries.map(\.amount).sum() }

    func totalsByCategory(_ entries: [LedgerEntry]) -> [SpendingCategory: Decimal] {
        Dictionary(grouping: entries, by: \.category).mapValues { total($0) }
    }

    /// Mean monthly spending across the most recent complete months that have spending.
    var typicalMonthlySpending: Decimal? {
        let totals = completeMonths(limit: configuration.baselineMonths)
            .map { total(spending(inMonth: $0)) }
            .filter { $0 > 0 }
            .prefix(configuration.typicalSpendingMonths)
        guard !totals.isEmpty else { return nil }
        return totals.sum() / Decimal(totals.count)
    }

    /// Month-end projection of `spent` so far: `spent + daily run rate × days left`, which equals
    /// `spent × daysInMonth ÷ elapsedDays`. Multiplying first keeps the result exact when it divides evenly.
    func projectedMonthTotal(spent: Decimal) -> Decimal {
        guard elapsedDays > 0 else { return spent }
        return spent * Decimal(daysInMonth) / Decimal(elapsedDays)
    }
}

extension Decimal {
    func rounded(scale: Int = 0) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .plain)
        return result
    }
}

extension Double {
    /// Whole-number percentage of a fraction (0.254 → 25).
    var wholePercent: Int { Int((self * 100).rounded()) }
}
