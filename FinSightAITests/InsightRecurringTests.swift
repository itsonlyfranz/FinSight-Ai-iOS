import XCTest
@testable import FinSightAI

/// Auto-detected recurring charges, subscriptions and price creep.
final class InsightRecurringTests: XCTestCase {
    private typealias F = InsightFixtures
    private let now = InsightFixtures.date(2026, 11, 15)
    private var calendar: Calendar { InsightFixtures.utc }

    /// Charges `daysAgo` days before `now`, newest listed last or first in any order.
    private func series(
        _ merchant: String,
        amounts: [Decimal],
        daysAgo: [Int],
        category: SpendingCategory = .entertainment,
        calendar: Calendar = InsightFixtures.utc,
        now: Date? = nil
    ) -> [LedgerEntry] {
        let anchor = now ?? self.now
        return zip(amounts, daysAgo).map { amount, days in
            F.spend(amount, category, merchant: merchant, on: calendar.date(byAdding: .day, value: -days, to: anchor)!)
        }
    }

    private func detect(_ entries: [LedgerEntry], calendar: Calendar = InsightFixtures.utc, now: Date? = nil) -> [DetectedRecurringCharge] {
        RecurringChargeDetector().detect(in: entries, now: now ?? self.now, calendar: calendar)
    }

    // MARK: - Cadence detection, table-driven

    func testCadenceDetectionTable() {
        struct Row {
            let label: String
            let daysAgo: [Int]
            let amounts: [Decimal]
            let cadence: RecurringCadence?
        }
        let rows = [
            Row(label: "monthly, 30-day gaps", daysAgo: [65, 35, 5], amounts: [720, 720, 720], cadence: .monthly),
            Row(label: "monthly, 28 and 31 day gaps", daysAgo: [64, 36, 5], amounts: [720, 720, 720], cadence: .monthly),
            Row(label: "monthly, four charges", daysAgo: [95, 65, 35, 5], amounts: [100, 100, 100, 100], cadence: .monthly),
            Row(label: "weekly", daysAgo: [22, 15, 8, 1], amounts: [100, 100, 100, 100], cadence: .weekly),
            Row(label: "weekly with one 8-day gap", daysAgo: [23, 15, 8, 1], amounts: [100, 100, 100, 100], cadence: .weekly),
            Row(label: "biweekly", daysAgo: [42, 28, 14], amounts: [250, 250, 250], cadence: .biweekly),
            Row(label: "quarterly", daysAgo: [190, 100, 9], amounts: [900, 900, 900], cadence: .quarterly),
            Row(label: "only two charges", daysAgo: [35, 5], amounts: [720, 720], cadence: nil),
            Row(label: "irregular gaps", daysAgo: [50, 40, 5], amounts: [720, 720, 720], cadence: nil),
            Row(label: "daily-ish purchases", daysAgo: [3, 2, 1], amounts: [90, 90, 90], cadence: nil),
            Row(label: "one gap off the cadence", daysAgo: [80, 35, 5], amounts: [720, 720, 720], cadence: nil),
            Row(label: "lapsed (last charge 50 days ago)", daysAgo: [110, 80, 50], amounts: [720, 720, 720], cadence: nil),
            Row(label: "just inside the active window (45 days)", daysAgo: [105, 75, 45], amounts: [720, 720, 720], cadence: .monthly),
            Row(label: "amounts all over the place", daysAgo: [65, 35, 5], amounts: [100, 400, 900], cadence: nil),
            Row(label: "variable bill within tolerance", daysAgo: [68, 38, 8], amounts: [3300, 3150, 3200], cadence: .monthly)
        ]
        for row in rows {
            let found = detect(series("Acme", amounts: row.amounts, daysAgo: row.daysAgo))
            XCTAssertEqual(found.first?.cadence, row.cadence, row.label)
            XCTAssertEqual(found.count, row.cadence == nil ? 0 : 1, row.label)
        }
    }

    func testDetectedChargeFields() throws {
        let entries = series("Meralco", amounts: [3300, 3150, 3200], daysAgo: [68, 38, 8], category: .bills)
        let charge = try XCTUnwrap(detect(entries).first)
        XCTAssertEqual(charge.merchant, "Meralco")
        XCTAssertEqual(charge.key, "meralco")
        XCTAssertEqual(charge.category, .bills)
        XCTAssertEqual(charge.occurrences, 3)
        XCTAssertEqual(charge.typicalAmount, 3200)
        XCTAssertEqual(charge.latestAmount, 3200)
        XCTAssertEqual(charge.previousAmount, 3150)
        XCTAssertFalse(charge.isFixedAmount, "a variable bill is not a fixed-price subscription")
        XCTAssertEqual(charge.monthlyEquivalent, 3200)
    }

    func testSameDayDuplicatesAreOneOccurrence() {
        var entries = series("Netflix", amounts: [720, 720, 720], daysAgo: [65, 35, 5])
        entries += series("Netflix", amounts: [720, 720, 720], daysAgo: [65, 35, 5])
        XCTAssertEqual(detect(entries).first?.occurrences, 3)
        // Two charges on one day plus one more is still only two occurrences.
        let thin = series("Netflix", amounts: [720, 720, 720], daysAgo: [35, 35, 5])
        XCTAssertTrue(detect(thin).isEmpty)
    }

    func testMerchantNameVariantsFormOneSeries() {
        let entries = [
            F.spend(720, .entertainment, merchant: "NETFLIX.COM", on: calendar.date(byAdding: .day, value: -65, to: now)!),
            F.spend(720, .entertainment, merchant: "Netflix", on: calendar.date(byAdding: .day, value: -35, to: now)!),
            F.spend(720, .entertainment, merchant: "netflix  #8841", on: calendar.date(byAdding: .day, value: -5, to: now)!)
        ]
        let found = detect(entries)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.cadence, .monthly)
    }

    func testBlankMerchantsAndNonSpendingEntriesAreIgnored() {
        let blank = series("", amounts: [720, 720, 720], daysAgo: [65, 35, 5])
        XCTAssertTrue(detect(blank).isEmpty)
        let income = (series("Salary", amounts: [5000, 5000, 5000], daysAgo: [65, 35, 5]) as [LedgerEntry]).map {
            LedgerEntry(amount: $0.amount, kind: .income, category: $0.category, merchant: $0.merchant, date: $0.date)
        }
        XCTAssertTrue(detect(income).isEmpty)
        let savings = series("BPI", amounts: [2500, 2500, 2500], daysAgo: [65, 35, 5], category: .savings)
        XCTAssertTrue(detect(savings).isEmpty, "savings transfers are not subscriptions")
    }

    func testFutureDatedChargesAreIgnored() {
        let entries = series("Netflix", amounts: [720, 720, 720], daysAgo: [35, 5, -25])
        XCTAssertTrue(detect(entries).isEmpty, "only two charges have happened")
    }

    func testResultsAreSortedByMonthlyCost() {
        let entries = series("Small", amounts: [100, 100, 100], daysAgo: [65, 35, 5])
            + series("Big", amounts: [900, 900, 900], daysAgo: [66, 36, 6])
            + series("Gym", amounts: [100, 100, 100, 100], daysAgo: [22, 15, 8, 1])
        let keys = detect(entries).map(\.key)
        XCTAssertEqual(keys, ["big", "gym", "small"], "weekly 100 ≈ 433/month sits between 900 and 100")
    }

    // MARK: - Monthly equivalents and next dates

    func testMonthlyEquivalentTable() {
        let cases: [(RecurringCadence, Decimal, Decimal)] = [
            (.weekly, 120, 520), (.biweekly, 120, 260), (.monthly, 120, 120), (.quarterly, 120, 40)
        ]
        for (cadence, amount, expected) in cases {
            XCTAssertEqual(cadence.monthlyEquivalent(of: amount), expected, "\(cadence)")
        }
    }

    func testNextExpectedDateFollowsTheCalendar() throws {
        // 31 Jan → 28 Feb (not 3 Mar), and a quarterly charge lands three calendar months later.
        let cases: [(RecurringCadence, Date, Date)] = [
            (.monthly, F.date(2026, 1, 31), F.date(2026, 2, 28)),
            (.monthly, F.date(2028, 1, 31), F.date(2028, 2, 29)),
            (.monthly, F.date(2026, 12, 15), F.date(2027, 1, 15)),
            (.weekly, F.date(2026, 2, 25), F.date(2026, 3, 4)),
            (.biweekly, F.date(2026, 12, 25), F.date(2027, 1, 8)),
            (.quarterly, F.date(2026, 11, 30), F.date(2027, 2, 28))
        ]
        for (cadence, last, expected) in cases {
            XCTAssertEqual(RecurringChargeDetector.nextDate(after: last, cadence: cadence, calendar: calendar), expected, "\(cadence) after \(last)")
        }
    }

    func testMonthEndChargesAreStillMonthly() throws {
        // Jan 31, Feb 28, Mar 31: gaps of 28 and 31 days.
        let entries = [
            F.spend(500, .bills, merchant: "Landlord", on: F.date(2026, 1, 31)),
            F.spend(500, .bills, merchant: "Landlord", on: F.date(2026, 2, 28)),
            F.spend(500, .bills, merchant: "Landlord", on: F.date(2026, 3, 31))
        ]
        let found = detect(entries, now: F.date(2026, 4, 5))
        XCTAssertEqual(found.first?.cadence, .monthly)
        XCTAssertEqual(found.first?.nextExpectedDate, F.date(2026, 4, 30))
    }

    // MARK: - Daylight-saving time

    func testWeeklyChargesAcrossASpringForwardAreStillWeekly() {
        // 167 hours separate Fri 6 Mar 00:30 and Fri 13 Mar 00:30 in New York, but it is 7 calendar days.
        let ny = F.newYork
        let dates = [(2, 27), (3, 6), (3, 13), (3, 20)].map { F.date(2026, $0.0, $0.1, hour: 0, minute: 30, in: ny) }
        let entries = dates.map { F.spend(100, .health, merchant: "Pilates", on: $0) }
        let found = detect(entries, calendar: ny, now: F.date(2026, 3, 22, in: ny))
        XCTAssertEqual(found.first?.cadence, .weekly)
        XCTAssertEqual(found.first?.occurrences, 4)
    }

    func testMonthlyChargesAcrossBothDSTChangesAreStillMonthly() {
        let ny = F.newYork
        let dates = [(2, 15), (3, 15), (4, 15)].map { F.date(2026, $0.0, $0.1, hour: 23, minute: 30, in: ny) }
        XCTAssertEqual(detect(dates.map { F.spend(50, .bills, merchant: "Cloud", on: $0) }, calendar: ny, now: F.date(2026, 4, 20, in: ny)).first?.cadence, .monthly)
        let fall = [(9, 30), (10, 30), (11, 30)].map { F.date(2026, $0.0, $0.1, hour: 0, minute: 15, in: ny) }
        XCTAssertEqual(detect(fall.map { F.spend(50, .bills, merchant: "Cloud", on: $0) }, calendar: ny, now: F.date(2026, 12, 3, in: ny)).first?.cadence, .monthly)
    }

    func testDayGapsIgnoreTheDSTHour() {
        let ny = F.newYork
        // Midnight 8 Mar to midnight 9 Mar is 23 hours but exactly one calendar day.
        XCTAssertEqual(RecurringChargeDetector.days(from: F.date(2026, 3, 8, hour: 0, in: ny), to: F.date(2026, 3, 9, hour: 0, in: ny), calendar: ny), 1)
        // Midnight 1 Nov to midnight 2 Nov is 25 hours but still one day.
        XCTAssertEqual(RecurringChargeDetector.days(from: F.date(2026, 11, 1, hour: 0, in: ny), to: F.date(2026, 11, 2, hour: 0, in: ny), calendar: ny), 1)
        XCTAssertEqual(RecurringChargeDetector.days(from: F.date(2026, 11, 1, hour: 23, minute: 59, in: ny), to: F.date(2026, 11, 2, hour: 0, minute: 1, in: ny), calendar: ny), 1)
        XCTAssertEqual(RecurringChargeDetector.days(from: F.date(2026, 3, 8, hour: 12, in: ny), to: F.date(2026, 3, 8, hour: 18, in: ny), calendar: ny), 0)
    }

    // MARK: - Subscription summary insight

    func testSubscriptionSummaryTotalsTheMonthlyCost() throws {
        let entries = series("Netflix", amounts: [720, 720, 720], daysAgo: [65, 35, 5])
            + series("Pilates", amounts: [100, 100, 100, 100], daysAgo: [22, 15, 8, 1], category: .health)
        let summary = try XCTUnwrap(F.run(now: now, entries: entries).first(.recurringCharges))
        // 720 + 100 × 52 / 12 = 1,153.33
        XCTAssertDecimal(summary.impactAmount, F.dec("1153.33"))
        XCTAssertEqual(summary.severity, .info)
        XCTAssertEqual(summary.id, "recurringCharges:2026-11")
        XCTAssertTrue(summary.evidence.contains(Insight.Evidence("Detected charges", .count(2))))
        XCTAssertTrue(summary.evidence.contains { $0.label == "Netflix · monthly" })
    }

    func testSubscriptionSummarySeverityDependsOnIncomeShare() {
        let entries = series("Netflix", amounts: [720, 720, 720], daysAgo: [65, 35, 5])
        let table: [(income: Decimal, severity: Insight.Severity)] = [
            (0, .info), (10_000, .info), (1_441, .info), (1_440, .notice), (1_000, .notice)
        ]
        for row in table {
            let summary = F.run(now: now, entries: entries, income: row.income).first(.recurringCharges)
            XCTAssertEqual(summary?.severity, row.severity, "income \(row.income)")
        }
    }

    func testNoSummaryWithoutRecurringCharges() {
        XCTAssertNil(F.run(now: now, entries: series("Netflix", amounts: [720, 720], daysAgo: [35, 5])).first(.recurringCharges))
    }

    // MARK: - Price creep

    func testPriceCreepTable() throws {
        struct Row {
            let label: String
            let amounts: [Decimal]
            let severity: Insight.Severity?
            let annual: Decimal
        }
        let rows = [
            Row(label: "unchanged", amounts: [720, 720, 720], severity: nil, annual: 0),
            Row(label: "+2.8% is under the 3% line", amounts: [720, 720, 740], severity: nil, annual: 0),
            Row(label: "+3.06%", amounts: [720, 720, 742], severity: .notice, annual: 264),
            Row(label: "+9.9% stays a notice", amounts: [720, 720, 791], severity: .notice, annual: 852),
            Row(label: "+10% is a warning", amounts: [720, 720, 792], severity: .warning, annual: 864),
            Row(label: "+11%", amounts: [720, 720, 800], severity: .warning, annual: 960),
            Row(label: "doubled exactly", amounts: [720, 720, 1440], severity: .warning, annual: 8640),
            Row(label: "more than doubled is a different purchase", amounts: [720, 720, 1500], severity: nil, annual: 0),
            Row(label: "a price drop is not creep", amounts: [720, 720, 600], severity: nil, annual: 0),
            Row(label: "previous prices were not stable", amounts: [720, 760, 800], severity: nil, annual: 0),
            Row(label: "earlier creep already absorbed", amounts: [600, 720, 720, 720], severity: nil, annual: 0)
        ]
        for row in rows {
            let daysAgo = row.amounts.count == 3 ? [65, 35, 5] : [95, 65, 35, 5]
            let entries = series("Netflix", amounts: row.amounts, daysAgo: daysAgo)
            let creep = F.run(now: now, entries: entries).first(.priceCreep)
            if let severity = row.severity {
                let found = try XCTUnwrap(creep, row.label)
                XCTAssertEqual(found.severity, severity, row.label)
                XCTAssertDecimal(found.impactAmount, row.annual, row.label)
                XCTAssertEqual(found.merchant, "Netflix")
                XCTAssertEqual(found.id, "priceCreep:netflix:2026-11")
                XCTAssertEqual(found.money("Previous charge"), 720)
            } else {
                XCTAssertNil(creep, row.label)
            }
        }
    }

    func testSubscriptionStaysRecurringAfterABigPriceRise() throws {
        // The month after a 40% rise the series is 10,10,10,10,14,14: still one fixed-price subscription.
        let entries = series("Netflix", amounts: [10, 10, 10, 10, 14, 14], daysAgo: [155, 125, 95, 65, 35, 5])
        let charge = try XCTUnwrap(detect(entries).first)
        XCTAssertTrue(charge.isFixedAmount)
        XCTAssertEqual(charge.typicalAmount, 14)
        XCTAssertEqual(charge.previousAmount, 14)
        XCTAssertDecimal(charge.monthlyEquivalent, 14)
        XCTAssertNil(F.run(now: now, entries: entries).first(.priceCreep), "the rise was already reported last month")

        // A further rise on the new price is price creep again.
        let again = series("Netflix", amounts: [10, 10, 10, 14, 14, 16], daysAgo: [155, 125, 95, 65, 35, 5])
        let creep = try XCTUnwrap(F.run(now: now, entries: again).first(.priceCreep))
        XCTAssertEqual(creep.money("Previous charge"), 14)

        // A variable bill whose amounts only briefly line up is not a fixed-price subscription.
        let bill = series("Meralco", amounts: [3000, 3300, 3100, 3102, 3400], daysAgo: [125, 95, 65, 35, 5], category: .bills)
        XCTAssertEqual(detect(bill).first?.isFixedAmount, false)
        XCTAssertNil(F.run(now: now, entries: bill).first(.priceCreep))

        // A 60% rise keeps the merchant recurring, so the new regular charge is not an outlier.
        let big = series("Netflix", amounts: [10, 10, 10, 10, 16, 16], daysAgo: [155, 125, 95, 65, 35, 5])
        let insights = F.run(now: now, entries: big)
        XCTAssertEqual(detect(big).first?.typicalAmount, 16)
        XCTAssertNil(insights.first(.merchantAnomaly))
    }

    func testPriceCreepOnAWeeklyChargeAnnualizesByChargesPerYear() throws {
        let entries = series("Gym", amounts: [100, 100, 110], daysAgo: [15, 8, 1], category: .health)
        let creep = try XCTUnwrap(F.run(now: now, entries: entries).first(.priceCreep))
        XCTAssertDecimal(creep.impactAmount, 520)   // +10 × 52
    }

    func testStalePriceCreepIsNotReported() {
        // Quarterly subscription whose hike was 100 days ago: still recurring, no longer news.
        let entries = series("Insurance", amounts: [900, 900, 990], daysAgo: [282, 191, 100], category: .bills)
        let insights = F.run(now: now, entries: entries)
        XCTAssertNotNil(insights.first(.recurringCharges))
        XCTAssertNil(insights.first(.priceCreep))
        // The same hike 40 days ago is reported.
        let fresh = series("Insurance", amounts: [900, 900, 990], daysAgo: [222, 131, 40], category: .bills)
        XCTAssertNotNil(F.run(now: now, entries: fresh).first(.priceCreep))
    }

    func testPriceCreepIdChangesWithTheMonthOfTheLatestCharge() throws {
        let november = try XCTUnwrap(F.run(now: now, entries: series("Netflix", amounts: [720, 720, 800], daysAgo: [65, 35, 5])).first(.priceCreep))
        let december = try XCTUnwrap(F.run(now: F.date(2026, 12, 2), entries: series("Netflix", amounts: [720, 720, 800], daysAgo: [65, 35, 5], now: now)).first(.priceCreep))
        XCTAssertEqual(november.id, "priceCreep:netflix:2026-11")
        XCTAssertEqual(december.id, "priceCreep:netflix:2026-11", "the same hike keeps one id, so a dismissal sticks")
    }

    func testVariableBillsNeverTriggerPriceCreep() {
        let entries = series("Meralco", amounts: [3300, 3150, 3600], daysAgo: [68, 38, 8], category: .bills)
        XCTAssertNil(F.run(now: now, entries: entries).first(.priceCreep))
    }
}
