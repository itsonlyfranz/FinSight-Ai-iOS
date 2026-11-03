import XCTest
@testable import FinSightAI

/// Budget breach, projected overrun, and the date boundaries every detector depends on.
final class InsightBudgetAndBoundaryTests: XCTestCase {
    private typealias F = InsightFixtures
    private let utc = InsightFixtures.utc

    private func groceriesBudget(_ limit: Decimal = 1000) -> [BudgetLimit] {
        [BudgetLimit(category: .groceries, limit: limit)]
    }

    // MARK: - Breach vs projection, table-driven (now = 15 Nov 2026, 15 of 30 days elapsed)

    func testBudgetStatusTable() {
        struct Row {
            let spent: Decimal
            let kind: Insight.Kind?
            let severity: Insight.Severity?
            let impact: Decimal
        }
        let rows = [
            Row(spent: 0, kind: nil, severity: nil, impact: 0),
            Row(spent: 400, kind: nil, severity: nil, impact: 0),         // projects to 800
            Row(spent: 500, kind: nil, severity: nil, impact: 0),         // projects to exactly 1000: not over
            Row(spent: 600, kind: .projectedOverrun, severity: .notice, impact: 200),   // 1200 = 120%
            Row(spent: 625, kind: .projectedOverrun, severity: .warning, impact: 250),  // 1250 = 125%
            Row(spent: 700, kind: .projectedOverrun, severity: .warning, impact: 400),
            Row(spent: 1000, kind: .projectedOverrun, severity: .warning, impact: 1000), // at the limit, not over yet
            Row(spent: 1001, kind: .budgetBreach, severity: .warning, impact: 1),
            Row(spent: 1249, kind: .budgetBreach, severity: .warning, impact: 249),
            Row(spent: 1250, kind: .budgetBreach, severity: .critical, impact: 250),
            Row(spent: 5000, kind: .budgetBreach, severity: .critical, impact: 4000)
        ]
        for row in rows {
            let entries = row.spent > 0 ? [F.spend(row.spent, .groceries, on: F.date(2026, 11, 3))] : []
            let insights = F.run(now: F.date(2026, 11, 15), entries: entries, budgets: groceriesBudget())
            let budgetInsights = insights.filter { $0.kind == .budgetBreach || $0.kind == .projectedOverrun }
            if let kind = row.kind {
                XCTAssertEqual(budgetInsights.count, 1, "spent \(row.spent)")
                XCTAssertEqual(budgetInsights.first?.kind, kind, "spent \(row.spent)")
                XCTAssertEqual(budgetInsights.first?.severity, row.severity, "spent \(row.spent)")
                XCTAssertDecimal(budgetInsights.first?.impactAmount, row.impact, "spent \(row.spent)")
                XCTAssertEqual(budgetInsights.first?.category, .groceries)
            } else {
                XCTAssertTrue(budgetInsights.isEmpty, "spent \(row.spent) should raise nothing, got \(budgetInsights.map(\.kind))")
            }
        }
    }

    func testProjectionIsRunRateTimesDaysLeftAndCarriesItsEvidence() throws {
        let insights = F.run(
            now: F.date(2026, 11, 10),
            entries: [F.spend(450, .groceries, on: F.date(2026, 11, 2))],
            budgets: groceriesBudget()
        )
        let overrun = try XCTUnwrap(insights.first(.projectedOverrun))
        // 450 over 10 days = 45/day; 20 days left → 450 + 900 = 1350.
        XCTAssertDecimal(overrun.money("Projected month total"), 1350)
        XCTAssertDecimal(overrun.money("Daily run rate"), 45)
        XCTAssertDecimal(overrun.impactAmount, 350)
        XCTAssertTrue(overrun.evidence.contains(Insight.Evidence("Days left", .days(20))))
        XCTAssertTrue(overrun.suggestedAction.contains("28"), "allowance (1000−450)/20 = 27.5 rounds to 28: \(overrun.suggestedAction)")
        XCTAssertEqual(overrun.id, "projectedOverrun:groceries:2026-11")
    }

    // MARK: - Month lengths and the last day of the month

    func testProjectionAcrossMonthLengthsTable() {
        struct Row {
            let label: String
            let now: Date
            let spent: Decimal
            let expectOverrun: Decimal?   // projected overage, nil = no insight
        }
        let rows = [
            // elapsed < 5: too early to extrapolate
            Row(label: "day 4", now: F.date(2026, 11, 4), spent: 900, expectOverrun: nil),
            Row(label: "day 5", now: F.date(2026, 11, 5), spent: 200, expectOverrun: 200),     // 200/5*30 = 1200
            Row(label: "31-day month, day 10", now: F.date(2026, 12, 10), spent: 400, expectOverrun: 240),   // 40*31 = 1240
            Row(label: "30-day month, day 10", now: F.date(2026, 11, 10), spent: 400, expectOverrun: 200),   // 40*30 = 1200
            Row(label: "Feb 2026 (28 days) day 14", now: F.date(2026, 2, 14), spent: 600, expectOverrun: 200), // 600/14*28 = 1200
            Row(label: "Feb 2028 (leap, 29 days) day 12", now: F.date(2028, 2, 12), spent: 480, expectOverrun: 160), // 40*29 = 1160
            // last day: nothing left to project, breach is the only possible finding
            Row(label: "last day of 31-day month", now: F.date(2026, 1, 31), spent: 900, expectOverrun: nil),
            Row(label: "last day of Feb 2026", now: F.date(2026, 2, 28), spent: 999, expectOverrun: nil),
            Row(label: "last day of leap Feb", now: F.date(2028, 2, 29), spent: 999, expectOverrun: nil),
            Row(label: "30th of a 30-day month", now: F.date(2026, 4, 30, hour: 23, minute: 59, second: 59), spent: 1000, expectOverrun: nil)
        ]
        for row in rows {
            let monthStart = F.date(
                utc.component(.year, from: row.now), utc.component(.month, from: row.now), 1
            )
            let insights = F.run(
                now: row.now,
                entries: [F.spend(row.spent, .groceries, on: monthStart)],
                budgets: groceriesBudget()
            )
            let overrun = insights.first(.projectedOverrun)
            if let expected = row.expectOverrun {
                XCTAssertDecimal(overrun?.impactAmount, expected, row.label)
            } else {
                XCTAssertNil(overrun, row.label)
            }
        }
    }

    func testOnTheLastDayAnOverspentBudgetIsABreachNotAProjection() {
        let insights = F.run(
            now: F.date(2026, 1, 31, hour: 23, minute: 30),
            entries: [F.spend(1100, .groceries, on: F.date(2026, 1, 31, hour: 8))],
            budgets: groceriesBudget()
        )
        XCTAssertEqual(insights.first(.budgetBreach)?.impactAmount, 100)
        XCTAssertNil(insights.first(.projectedOverrun))
    }

    // MARK: - Month boundaries (UTC)

    func testMonthBoundaryTable() {
        struct Row {
            let label: String
            let now: Date
            let entryDate: Date
            let counted: Bool
        }
        let rows = [
            Row(label: "1 second before the month", now: F.date(2026, 11, 15), entryDate: F.date(2026, 10, 31, hour: 23, minute: 59, second: 59), counted: false),
            Row(label: "midnight starting the month", now: F.date(2026, 11, 15), entryDate: F.date(2026, 11, 1, hour: 0), counted: true),
            Row(label: "a future day this month", now: F.date(2026, 11, 15), entryDate: F.date(2026, 11, 16, hour: 0), counted: false),
            Row(label: "later today", now: F.date(2026, 11, 15, hour: 9), entryDate: F.date(2026, 11, 15, hour: 23, minute: 59, second: 59), counted: true),
            Row(label: "start of today", now: F.date(2026, 11, 15, hour: 9), entryDate: F.date(2026, 11, 15, hour: 0), counted: true),
            Row(label: "last second of the 30th", now: F.date(2026, 11, 30, hour: 12), entryDate: F.date(2026, 11, 30, hour: 23, minute: 59, second: 59), counted: true),
            Row(label: "midnight starting next month", now: F.date(2026, 11, 30, hour: 12), entryDate: F.date(2026, 12, 1, hour: 0), counted: false),
            Row(label: "31st of a 31-day month", now: F.date(2026, 12, 31, hour: 20), entryDate: F.date(2026, 12, 31, hour: 1), counted: true),
            Row(label: "leap day", now: F.date(2028, 2, 29, hour: 20), entryDate: F.date(2028, 2, 29, hour: 0), counted: true),
            Row(label: "Mar 1 is not Feb", now: F.date(2028, 2, 29, hour: 20), entryDate: F.date(2028, 3, 1, hour: 0), counted: false),
            Row(label: "year boundary backwards", now: F.date(2027, 1, 15), entryDate: F.date(2026, 12, 31, hour: 23, minute: 59, second: 59), counted: false),
            Row(label: "year boundary forwards", now: F.date(2027, 1, 15), entryDate: F.date(2027, 1, 1, hour: 0), counted: true)
        ]
        for row in rows {
            let insights = F.run(
                now: row.now,
                entries: [F.spend(1100, .groceries, on: row.entryDate)],
                budgets: groceriesBudget()
            )
            XCTAssertEqual(insights.first(.budgetBreach) != nil, row.counted, row.label)
        }
    }

    // MARK: - Daylight-saving time

    func testDSTMonthBoundariesInNewYork() {
        let ny = F.newYork
        struct Row {
            let label: String
            let now: Date
            let entryDate: Date
            let counted: Bool
        }
        let rows = [
            // US spring forward: 8 March 2026 (02:00 → 03:00).
            Row(label: "March starts at local midnight", now: F.date(2026, 3, 9, in: ny), entryDate: F.date(2026, 3, 1, hour: 0, in: ny), counted: true),
            Row(label: "last second of February", now: F.date(2026, 3, 9, in: ny), entryDate: F.date(2026, 2, 28, hour: 23, minute: 59, second: 59, in: ny), counted: false),
            Row(label: "the short day itself", now: F.date(2026, 3, 8, hour: 18, in: ny), entryDate: F.date(2026, 3, 8, hour: 1, minute: 59, in: ny), counted: true),
            Row(label: "the day after the short day", now: F.date(2026, 3, 8, hour: 18, in: ny), entryDate: F.date(2026, 3, 9, hour: 0, minute: 30, in: ny), counted: false),
            // US fall back: 1 November 2026 (02:00 → 01:00), so 1 Nov is 25 hours long.
            Row(label: "November starts at local midnight", now: F.date(2026, 11, 2, in: ny), entryDate: F.date(2026, 11, 1, hour: 0, in: ny), counted: true),
            Row(label: "late October evening", now: F.date(2026, 11, 2, in: ny), entryDate: F.date(2026, 10, 31, hour: 23, minute: 30, in: ny), counted: false),
            Row(label: "the long day, last minute", now: F.date(2026, 11, 1, hour: 23, minute: 59, in: ny), entryDate: F.date(2026, 11, 1, hour: 23, minute: 58, in: ny), counted: true)
        ]
        for row in rows {
            let insights = F.run(
                now: row.now, calendar: ny,
                entries: [F.spend(1100, .groceries, on: row.entryDate)],
                budgets: groceriesBudget()
            )
            XCTAssertEqual(insights.first(.budgetBreach) != nil, row.counted, row.label)
        }
    }

    func testDaysElapsedAndLeftUseCalendarDaysAroundDST() throws {
        // 15 Mar 2026 in New York is the 15th calendar day even though March lost an hour; March has
        // 31 days, so 16 days are left.
        let ny = F.newYork
        let insights = F.run(
            now: F.date(2026, 3, 15, in: ny), calendar: ny,
            entries: [F.spend(600, .groceries, on: F.date(2026, 3, 2, in: ny))],
            budgets: groceriesBudget()
        )
        let overrun = try XCTUnwrap(insights.first(.projectedOverrun))
        XCTAssertTrue(overrun.evidence.contains(Insight.Evidence("Days left", .days(16))))
        XCTAssertDecimal(overrun.money("Projected month total"), 600 + 600 / 15 * 16)
    }

    func testTimeZoneChangesWhichMonthAnInstantBelongsTo() {
        // 2026-11-01 02:30 UTC is still 31 October in New York (EDT, UTC−4).
        let instant = F.date(2026, 11, 1, hour: 2, minute: 30, in: F.utc)
        let budgets = groceriesBudget()
        let now = F.date(2026, 11, 15, in: F.utc)
        let inUTC = F.run(now: now, calendar: F.utc, entries: [F.spend(1100, .groceries, on: instant)], budgets: budgets)
        let inNewYork = F.run(now: F.date(2026, 11, 15, in: F.newYork), calendar: F.newYork, entries: [F.spend(1100, .groceries, on: instant)], budgets: budgets)
        XCTAssertNotNil(inUTC.first(.budgetBreach))
        XCTAssertNil(inNewYork.first(.budgetBreach))
    }

    // MARK: - Budget details

    func testOnlyBudgetedSpendingCategoriesAreChecked() {
        let entries = [
            F.spend(2000, .dining, on: F.date(2026, 11, 3)),
            F.spend(2000, .savings, on: F.date(2026, 11, 3)),
            F.spend(2000, .groceries, on: F.date(2026, 11, 3), kind: .income),
            F.spend(2000, .groceries, on: F.date(2026, 11, 3), kind: .transfer)
        ]
        let budgets = [
            BudgetLimit(category: .groceries, limit: 1000),
            BudgetLimit(category: .savings, limit: 100),
            BudgetLimit(category: .transport, limit: 0)
        ]
        let insights = F.run(now: F.date(2026, 11, 15), entries: entries, budgets: budgets)
        XCTAssertNil(insights.first(.budgetBreach, category: .groceries), "income and transfers are not spending")
        XCTAssertNil(insights.first(.budgetBreach, category: .savings), "savings are set aside, not spent")
        XCTAssertNil(insights.first(.budgetBreach, category: .dining), "no budget on dining")
        XCTAssertNil(insights.first(.budgetBreach, category: .transport), "a zero limit is not a budget")
    }

    func testRolloverStyleLimitsComeStraightFromTheCaller() {
        // The engine uses the limit it is given (base + carry-over); 1100 spent is fine under 1500.
        let insights = F.run(
            now: F.date(2026, 11, 30),
            entries: [F.spend(1100, .groceries, on: F.date(2026, 11, 3))],
            budgets: groceriesBudget(1500)
        )
        XCTAssertNil(insights.first(.budgetBreach))
    }

    func testEmptyLedgerProducesNothing() {
        XCTAssertTrue(F.run(now: F.date(2026, 11, 15), entries: [], budgets: groceriesBudget(), income: 5000, reserve: 100).isEmpty)
    }
}
