import XCTest
@testable import FinSightAI

/// Savings rate, emergency-fund runway, no-spend streaks, ranking and suppression.
final class InsightSavingsRunwayStreakTests: XCTestCase {
    private typealias F = InsightFixtures
    private let now = InsightFixtures.date(2026, 11, 15)

    // MARK: - Savings rate (October is "last month")

    func testSavingsRateTable() throws {
        struct Row {
            let income: Decimal
            let spent: Decimal
            let severity: Insight.Severity
            let impact: Decimal
        }
        let rows = [
            Row(income: 10_000, spent: 7_500, severity: .info, impact: 2_500),      // 25% → amount saved
            Row(income: 10_000, spent: 8_000, severity: .info, impact: 2_000),      // exactly the 20% target
            Row(income: 10_000, spent: 8_001, severity: .notice, impact: 1),        // 19.99% → gap 1
            Row(income: 10_000, spent: 8_500, severity: .notice, impact: 500),      // 15%
            Row(income: 10_000, spent: 9_000, severity: .notice, impact: 1_000),    // 10% exactly
            Row(income: 10_000, spent: 9_001, severity: .warning, impact: 1_001),
            Row(income: 10_000, spent: 10_000, severity: .warning, impact: 2_000),  // 0%
            Row(income: 10_000, spent: 10_001, severity: .critical, impact: 2_001),
            Row(income: 10_000, spent: 12_000, severity: .critical, impact: 4_000)
        ]
        for row in rows {
            let entries = [F.spend(row.spent, .bills, on: F.date(2026, 10, 12))]
            let insight = try XCTUnwrap(F.run(now: now, entries: entries, income: row.income).first(.savingsRate), "spent \(row.spent)")
            XCTAssertEqual(insight.severity, row.severity, "spent \(row.spent)")
            XCTAssertDecimal(insight.impactAmount, row.impact, "spent \(row.spent)")
            XCTAssertEqual(insight.id, "savingsRate:2026-10")
            XCTAssertEqual(insight.money("Income"), row.income)
            XCTAssertEqual(insight.money("Spending"), row.spent)
        }
    }

    func testSavingsRateNeedsIncomeAndSpendingInThePreviousMonth() {
        let october = [F.spend(5_000, .bills, on: F.date(2026, 10, 12))]
        XCTAssertNil(F.run(now: now, entries: october, income: 0).first(.savingsRate), "no income known")
        XCTAssertNil(F.run(now: now, entries: [F.spend(5_000, .bills, on: F.date(2026, 11, 2))], income: 10_000).first(.savingsRate), "nothing logged last month")
        XCTAssertNil(F.run(now: now, entries: [F.spend(5_000, .bills, on: F.date(2026, 9, 12))], income: 10_000).first(.savingsRate), "September is not last month")
    }

    func testLoggedIncomeCountsAndSavingsDepositsAreNotSpending() throws {
        let entries = [
            F.spend(9_000, .bills, on: F.date(2026, 10, 12)),
            F.spend(10_000, .other, merchant: "Employer", on: F.date(2026, 10, 1), kind: .income),
            F.spend(1_000, .savings, on: F.date(2026, 10, 20)),                      // set aside, not spent
            F.spend(500, .shopping, on: F.date(2026, 10, 21), kind: .transfer)       // moves money, not spending
        ]
        let insight = try XCTUnwrap(F.run(now: now, entries: entries, income: 0).first(.savingsRate))
        XCTAssertEqual(insight.money("Spending"), 9_000)
        XCTAssertEqual(insight.money("Income"), 10_000)
        XCTAssertEqual(insight.severity, .notice)   // 10%
        // Income that is both a recurring source and a one-off bonus adds up.
        let withSource = try XCTUnwrap(F.run(now: now, entries: entries, income: 5_000).first(.savingsRate))
        XCTAssertEqual(withSource.money("Income"), 15_000)
    }

    func testSavingsRateAcrossAYearBoundary() {
        let insight = F.run(
            now: F.date(2027, 1, 20),
            entries: [F.spend(5_000, .bills, on: F.date(2026, 12, 31, hour: 23, minute: 59, second: 59))],
            income: 10_000
        ).first(.savingsRate)
        XCTAssertEqual(insight?.id, "savingsRate:2026-12")
        XCTAssertTrue(insight?.summary.contains("December") == true)
    }

    // MARK: - Runway (typical spending 1,000/month over Aug–Oct)

    private var steadySpending: [LedgerEntry] {
        F.monthly(.bills, amounts: [1000, 1000, 1000], endingBefore: 2026, 11)
    }

    func testRunwayTable() throws {
        struct Row {
            let reserve: Decimal
            let severity: Insight.Severity
            let impact: Decimal
            let months: Double
        }
        let rows = [
            Row(reserve: 0, severity: .warning, impact: 3_000, months: 0),      // critical by months, capped: probably untracked
            Row(reserve: 500, severity: .critical, impact: 2_500, months: 0.5),
            Row(reserve: 999, severity: .critical, impact: 2_001, months: 0.999),
            Row(reserve: 1_000, severity: .warning, impact: 2_000, months: 1),
            Row(reserve: 2_999, severity: .warning, impact: 1, months: 2.999),
            Row(reserve: 3_000, severity: .notice, impact: 3_000, months: 3),
            Row(reserve: 5_999, severity: .notice, impact: 1, months: 5.999),
            Row(reserve: 6_000, severity: .info, impact: 6_000, months: 6),
            Row(reserve: 12_000, severity: .info, impact: 12_000, months: 12)
        ]
        for row in rows {
            let insight = try XCTUnwrap(F.run(now: now, entries: steadySpending, reserve: row.reserve).first(.emergencyRunway), "reserve \(row.reserve)")
            XCTAssertEqual(insight.severity, row.severity, "reserve \(row.reserve)")
            XCTAssertDecimal(insight.impactAmount, row.impact, "reserve \(row.reserve)")
            let runway = insight.evidence.compactMap { item -> Double? in
                if case .months(let value) = item.value { return value }
                return nil
            }.first
            XCTAssertEqual(try XCTUnwrap(runway), row.months, accuracy: 0.0001, "reserve \(row.reserve)")
        }
    }

    func testRunwayUsesTheMostRecentThreeMonthsWithSpending() throws {
        // July 5,000 is older than the three most recent months, so it is ignored.
        let entries = F.monthly(.bills, amounts: [5000, 1000, 1000, 1000], endingBefore: 2026, 11)
        let insight = try XCTUnwrap(F.run(now: now, entries: entries, reserve: 3000).first(.emergencyRunway))
        XCTAssertEqual(insight.money("Typical monthly spending"), 1000)
        // A month with no spending is skipped rather than counted as zero.
        let gap = [
            F.spend(1500, .bills, on: F.date(2026, 8, 10)),
            F.spend(500, .bills, on: F.date(2026, 10, 10))
        ]
        let gapInsight = try XCTUnwrap(F.run(now: now, entries: gap, reserve: 3000).first(.emergencyRunway))
        XCTAssertEqual(gapInsight.money("Typical monthly spending"), 1000)
    }

    func testRunwayNeedsCompleteMonthOfSpendingAndIgnoresNegativeReserve() throws {
        XCTAssertNil(F.run(now: now, entries: [F.spend(1000, .bills, on: F.date(2026, 11, 2))], reserve: 5000).first(.emergencyRunway), "only the current, incomplete month")
        let insight = try XCTUnwrap(F.run(now: now, entries: steadySpending, reserve: -400).first(.emergencyRunway))
        XCTAssertEqual(insight.money("Reserve"), 0)
        XCTAssertEqual(insight.severity, .warning)
    }

    func testReserveCalculatorPrefersEmergencyGoals() {
        let goals = [GoalBalance(name: "Japan trip", saved: 500), GoalBalance(name: "Emergency Fund", saved: 2_000), GoalBalance(name: "emergency buffer", saved: 300)]
        XCTAssertEqual(ReserveCalculator.reserve(from: goals), 2_300)
        XCTAssertEqual(ReserveCalculator.reserve(from: [GoalBalance(name: "Laptop", saved: 400), GoalBalance(name: "Trip", saved: 600)]), 1_000)
        XCTAssertEqual(ReserveCalculator.reserve(from: []), 0)
    }

    // MARK: - No-spend streak (now = 15 Nov, noon)

    func testStreakTable() throws {
        struct Row {
            let label: String
            let spendDays: [Date]
            let streak: Int?
            let startsOn: String?
        }
        let rows = [
            Row(label: "spent yesterday", spendDays: [F.date(2026, 11, 14)], streak: nil, startsOn: nil),
            Row(label: "one quiet day is not a streak", spendDays: [F.date(2026, 11, 13)], streak: nil, startsOn: nil),
            Row(label: "two quiet days", spendDays: [F.date(2026, 11, 12)], streak: 2, startsOn: "2026-11-13"),
            Row(label: "today's spending doesn't break it", spendDays: [F.date(2026, 11, 15, hour: 9), F.date(2026, 11, 10)], streak: 4, startsOn: "2026-11-11"),
            Row(label: "streak runs across a month boundary", spendDays: [F.date(2026, 10, 28)], streak: 17, startsOn: "2026-10-29"),
            Row(label: "streak runs across a year boundary", spendDays: [F.date(2025, 12, 28)], streak: 90, startsOn: "2026-08-17"),   // capped at 90
            Row(label: "most recent spend ends the streak", spendDays: [F.date(2026, 10, 1), F.date(2026, 11, 8)], streak: 6, startsOn: "2026-11-09")
        ]
        for row in rows {
            let entries = row.spendDays.map { F.spend(50, .dining, on: $0) }
            let insight = F.run(now: now, entries: entries).first(.noSpendStreak)
            if let streak = row.streak {
                let found = try XCTUnwrap(insight, row.label)
                XCTAssertTrue(found.evidence.contains(Insight.Evidence("Streak", .days(streak))), "\(row.label): \(found.evidence)")
                XCTAssertEqual(found.id, "noSpendStreak:\(row.startsOn!)", row.label)
                XCTAssertEqual(found.severity, .info)
            } else {
                XCTAssertNil(insight, row.label)
            }
        }
    }

    func testStreakIgnoresIncomeTransfersAndSavingsDeposits() throws {
        let entries = [
            F.spend(50, .dining, on: F.date(2026, 11, 10)),
            F.spend(5000, .other, on: F.date(2026, 11, 12), kind: .income),
            F.spend(300, .shopping, on: F.date(2026, 11, 13), kind: .transfer),
            F.spend(900, .savings, on: F.date(2026, 11, 14))
        ]
        let insight = try XCTUnwrap(F.run(now: now, entries: entries).first(.noSpendStreak))
        XCTAssertTrue(insight.evidence.contains(Insight.Evidence("Streak", .days(4))))
    }

    func testStreakNeedsAnySpendingHistory() {
        XCTAssertNil(F.run(now: now, entries: [F.spend(5000, .other, on: F.date(2026, 11, 2), kind: .income)]).first(.noSpendStreak))
    }

    func testStreakAcrossSpringForwardAndFallBack() throws {
        let ny = F.newYork
        // Spent on 6 Mar; now is noon on 12 Mar, so the completed quiet days are 7–11 Mar (8 Mar has 23 hours).
        let spring = try XCTUnwrap(F.run(
            now: F.date(2026, 3, 12, in: ny), calendar: ny,
            entries: [F.spend(50, .dining, on: F.date(2026, 3, 6, in: ny))]
        ).first(.noSpendStreak))
        XCTAssertTrue(spring.evidence.contains(Insight.Evidence("Streak", .days(5))))
        XCTAssertEqual(spring.id, "noSpendStreak:2026-03-07")

        // Spent on 29 Oct; quiet days 30 Oct, 31 Oct, 1 Nov (25 hours), 2 Nov before noon on 3 Nov.
        let fall = try XCTUnwrap(F.run(
            now: F.date(2026, 11, 3, in: ny), calendar: ny,
            entries: [F.spend(50, .dining, on: F.date(2026, 10, 29, in: ny))]
        ).first(.noSpendStreak))
        XCTAssertTrue(fall.evidence.contains(Insight.Evidence("Streak", .days(4))))
        XCTAssertEqual(fall.id, "noSpendStreak:2026-10-30")
    }

    func testStreakAtLateNightAndJustAfterMidnight() throws {
        // At 00:05 on the 15th the 14th is yesterday and complete; spending late on the 12th ends the run.
        let entries = [F.spend(50, .dining, on: F.date(2026, 11, 12, hour: 23, minute: 59))]
        let early = try XCTUnwrap(F.run(now: F.date(2026, 11, 15, hour: 0, minute: 5), entries: entries).first(.noSpendStreak))
        XCTAssertTrue(early.evidence.contains(Insight.Evidence("Streak", .days(2))))
        let late = try XCTUnwrap(F.run(now: F.date(2026, 11, 15, hour: 23, minute: 59), entries: entries).first(.noSpendStreak))
        XCTAssertTrue(late.evidence.contains(Insight.Evidence("Streak", .days(2))), "the same completed days regardless of time of day")
    }

    func testStreakImpactEstimatesAvoidedSpending() throws {
        // Typical spending 3,000/month → 100/day; a 4-day streak avoids ~400.
        let entries = F.monthly(.bills, amounts: [3000, 3000, 3000], endingBefore: 2026, 11)
            + [F.spend(50, .dining, on: F.date(2026, 11, 10))]
        let insight = try XCTUnwrap(F.run(now: now, entries: entries).first(.noSpendStreak))
        XCTAssertDecimal(insight.impactAmount, 400)
    }

    // MARK: - Ranking and determinism

    func testInsightsAreRankedBySeverityThenImpact() {
        let entries = [
            F.spend(1500, .groceries, on: F.date(2026, 11, 3)),      // 150% of budget → critical
            F.spend(1100, .dining, on: F.date(2026, 11, 3))          // 110% → warning
        ] + F.monthly(.bills, amounts: [1000, 1000, 1000], endingBefore: 2026, 11)
        let insights = F.run(
            now: now, entries: entries,
            budgets: [BudgetLimit(category: .groceries, limit: 1000), BudgetLimit(category: .dining, limit: 1000)],
            income: 20_000, reserve: 300
        )
        XCTAssertGreaterThan(insights.count, 3)
        for pair in zip(insights, insights.dropFirst()) {
            if pair.0.severity == pair.1.severity {
                XCTAssertGreaterThanOrEqual(pair.0.impactAmount, pair.1.impactAmount, "\(pair.0.id) before \(pair.1.id)")
            } else {
                XCTAssertGreaterThan(pair.0.severity, pair.1.severity)
            }
        }
        XCTAssertEqual(insights.first?.severity, .critical)
        XCTAssertEqual(Set(insights.map(\.id)).count, insights.count, "ids are unique")
    }

    func testOutputIsIndependentOfInputOrderAndRepeatable() {
        var entries: [LedgerEntry] = []
        for month in 6...10 {
            entries.append(F.spend(100 + Decimal(month), .dining, merchant: "Cafe Luna", on: F.date(2026, month, 3 + month)))
            entries.append(F.spend(720, .entertainment, merchant: "Netflix", on: F.date(2026, month, 10)))
            entries.append(F.spend(1000, .groceries, on: F.date(2026, month, 12)))
        }
        entries.append(F.spend(500, .dining, merchant: "Cafe Luna", on: F.date(2026, 11, 9)))
        entries.append(F.spend(1900, .groceries, on: F.date(2026, 11, 6)))
        let budgets = [BudgetLimit(category: .groceries, limit: 1500)]

        let baseline = F.run(now: now, entries: entries, budgets: budgets, income: 9000, reserve: 2500)
        XCTAssertFalse(baseline.isEmpty)
        for seed in 0..<5 {
            var shuffled = entries
            var generator = SeededGenerator(seed: UInt64(seed + 1))
            shuffled.shuffle(using: &generator)
            XCTAssertEqual(F.run(now: now, entries: shuffled, budgets: budgets, income: 9000, reserve: 2500), baseline, "shuffle \(seed)")
        }
        XCTAssertEqual(F.run(now: now, entries: entries, budgets: budgets, income: 9000, reserve: 2500), baseline)
    }

    func testEntriesOutsideTheHistoryAndFutureEntriesDoNotChangeCurrentFindings() {
        let base = [F.spend(1100, .groceries, on: F.date(2026, 11, 3))]
        let noisy = base + [F.spend(9000, .groceries, on: F.date(2026, 12, 20))]
        let budgets = [BudgetLimit(category: .groceries, limit: 1000)]
        XCTAssertEqual(F.run(now: now, entries: noisy, budgets: budgets), F.run(now: now, entries: base, budgets: budgets))
    }

    func testEveryInsightHasAnActionEvidenceAndStableMetadata() {
        var entries: [LedgerEntry] = []
        for month in 6...10 {
            entries.append(F.spend(720, .entertainment, merchant: "Netflix", on: F.date(2026, month, 10)))
            entries.append(F.spend(1000, .groceries, on: F.date(2026, month, 12)))
        }
        entries.append(F.spend(800, .entertainment, merchant: "Netflix", on: F.date(2026, 11, 10)))
        entries.append(F.spend(2600, .groceries, on: F.date(2026, 11, 6)))
        let insights = F.run(now: now, entries: entries, budgets: [BudgetLimit(category: .groceries, limit: 1500)], income: 9000, reserve: 500)
        let kinds = Set(insights.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.budgetBreach, .recurringCharges, .priceCreep, .emergencyRunway, .savingsRate]), "\(kinds)")
        for insight in insights {
            XCTAssertFalse(insight.title.isEmpty, insight.id)
            XCTAssertFalse(insight.summary.isEmpty, insight.id)
            XCTAssertFalse(insight.suggestedAction.isEmpty, insight.id)
            XCTAssertFalse(insight.evidence.isEmpty, insight.id)
            XCTAssertGreaterThanOrEqual(insight.impactAmount, 0, insight.id)
            XCTAssertTrue(insight.id.hasPrefix(insight.kind.rawValue + ":"), insight.id)
        }
    }

    // MARK: - Dismiss and snooze

    func testVisibilityTable() {
        let insights = ["a", "b", "c", "d"].map {
            Insight(id: $0, kind: .budgetBreach, severity: .warning, title: $0, summary: $0, impactAmount: 1, evidence: [], suggestedAction: $0)
        }
        let day = { (offset: Int) in self.now.addingTimeInterval(Double(offset) * 86_400) }
        struct Row {
            let label: String
            let suppressions: [InsightSuppression]
            let visible: [String]
        }
        let rows = [
            Row(label: "nothing suppressed", suppressions: [], visible: ["a", "b", "c", "d"]),
            Row(label: "dismissed stays hidden", suppressions: [.init(insightID: "a", status: .dismissed, until: nil)], visible: ["b", "c", "d"]),
            Row(label: "dismissal ignores a stray date", suppressions: [.init(insightID: "a", status: .dismissed, until: day(-5))], visible: ["b", "c", "d"]),
            Row(label: "snoozed until tomorrow", suppressions: [.init(insightID: "b", status: .snoozed, until: day(1))], visible: ["a", "c", "d"]),
            Row(label: "snooze ends exactly now", suppressions: [.init(insightID: "b", status: .snoozed, until: day(0))], visible: ["a", "b", "c", "d"]),
            Row(label: "snooze already over", suppressions: [.init(insightID: "b", status: .snoozed, until: day(-1))], visible: ["a", "b", "c", "d"]),
            Row(label: "snooze without an end date", suppressions: [.init(insightID: "b", status: .snoozed, until: nil)], visible: ["a", "b", "c", "d"]),
            Row(label: "unknown ids are ignored", suppressions: [.init(insightID: "zzz", status: .dismissed, until: nil)], visible: ["a", "b", "c", "d"]),
            Row(label: "mixed", suppressions: [
                .init(insightID: "a", status: .dismissed, until: nil),
                .init(insightID: "b", status: .snoozed, until: day(3)),
                .init(insightID: "c", status: .snoozed, until: day(-3))
            ], visible: ["c", "d"])
        ]
        for row in rows {
            let visible = InsightVisibility.visible(insights, suppressions: row.suppressions, now: now).map(\.id)
            XCTAssertEqual(visible, row.visible, row.label)
        }
    }

    func testADismissalOnlyHidesThatPeriodsFinding() {
        let entries = [F.spend(1100, .groceries, on: F.date(2026, 11, 3)), F.spend(1100, .groceries, on: F.date(2026, 12, 3))]
        let budgets = [BudgetLimit(category: .groceries, limit: 1000)]
        let november = F.run(now: F.date(2026, 11, 15), entries: entries, budgets: budgets).first(.budgetBreach)!
        let december = F.run(now: F.date(2026, 12, 15), entries: entries, budgets: budgets).first(.budgetBreach)!
        XCTAssertNotEqual(november.id, december.id)
        let dismissed = [InsightSuppression(insightID: november.id, status: .dismissed, until: nil)]
        XCTAssertTrue(InsightVisibility.visible([november], suppressions: dismissed, now: now).isEmpty)
        XCTAssertEqual(InsightVisibility.visible([december], suppressions: dismissed, now: now).count, 1)
    }
}

/// Deterministic shuffling for the order-independence test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
