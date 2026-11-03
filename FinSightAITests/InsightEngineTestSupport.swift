import XCTest
@testable import FinSightAI

/// Shared builders for the insight engine tests. Everything is anchored to explicit calendars and
/// dates so results never depend on the machine's time zone or on today's date.
enum InsightFixtures {
    static func calendar(_ identifier: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = 2
        return calendar
    }

    static let utc = calendar("UTC")
    static let newYork = calendar("America/New_York")

    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        hour: Int = 12, minute: Int = 0, second: Int = 0,
        in calendar: Calendar = utc
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func dec(_ text: String) -> Decimal { Decimal(string: text)! }

    static func spend(
        _ amount: Decimal,
        _ category: SpendingCategory = .groceries,
        merchant: String = "",
        on date: Date,
        kind: TransactionKind = .expense
    ) -> LedgerEntry {
        LedgerEntry(amount: amount, kind: kind, category: category, merchant: merchant, date: date)
    }

    /// One spending entry per listed month, all on `day`, with an empty merchant so the entries never
    /// form a recurring series or a merchant anomaly.
    static func monthly(
        _ category: SpendingCategory,
        amounts: [Decimal],
        endingBefore year: Int, _ month: Int,
        day: Int = 10,
        calendar: Calendar = utc
    ) -> [LedgerEntry] {
        // amounts[0] is the oldest month; the last one is the month right before (year, month).
        amounts.enumerated().map { index, amount in
            let offset = index - amounts.count
            let anchor = calendar.date(from: DateComponents(year: year, month: month, day: 1, hour: 12))!
            let target = calendar.date(byAdding: .month, value: offset, to: anchor)!
            let parts = calendar.dateComponents([.year, .month], from: target)
            return spend(amount, category, on: date(parts.year!, parts.month!, day, in: calendar))
        }
    }

    static func input(
        now: Date,
        calendar: Calendar = utc,
        entries: [LedgerEntry],
        budgets: [BudgetLimit] = [],
        income: Decimal = 0,
        reserve: Decimal = 0,
        configuration: InsightEngineConfiguration = InsightEngineConfiguration()
    ) -> InsightInput {
        InsightInput(
            now: now, calendar: calendar, entries: entries, budgets: budgets,
            recurringMonthlyIncome: income, reserveBalance: reserve, configuration: configuration
        )
    }

    static func run(
        now: Date,
        calendar: Calendar = utc,
        entries: [LedgerEntry],
        budgets: [BudgetLimit] = [],
        income: Decimal = 0,
        reserve: Decimal = 0,
        configuration: InsightEngineConfiguration = InsightEngineConfiguration()
    ) -> [Insight] {
        InsightEngine().insights(for: input(
            now: now, calendar: calendar, entries: entries, budgets: budgets,
            income: income, reserve: reserve, configuration: configuration
        ))
    }
}

extension Array where Element == Insight {
    func of(_ kind: Insight.Kind) -> [Insight] { filter { $0.kind == kind } }

    func first(_ kind: Insight.Kind, category: SpendingCategory? = nil) -> Insight? {
        first { $0.kind == kind && (category == nil || $0.category == category) }
    }
}

extension Insight {
    func money(_ label: String) -> Decimal? {
        for item in evidence where item.label == label {
            if case .money(let value) = item.value { return value }
        }
        return nil
    }
}

func XCTAssertDecimal(
    _ actual: Decimal?, _ expected: Decimal, accuracy: Decimal = Decimal(string: "0.01")!,
    _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    guard let actual else {
        XCTFail("value is nil; expected \(expected) \(message)", file: file, line: line)
        return
    }
    XCTAssertLessThanOrEqual(abs(actual - expected), accuracy, "\(actual) is not \(expected) ± \(accuracy). \(message)", file: file, line: line)
}
