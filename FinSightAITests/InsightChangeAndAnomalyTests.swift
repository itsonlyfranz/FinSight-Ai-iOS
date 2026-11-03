import XCTest
@testable import FinSightAI

/// Month-over-month change and robust-z anomalies.
final class InsightChangeAndAnomalyTests: XCTestCase {
    private typealias F = InsightFixtures

    // MARK: - Statistics

    func testMedianTable() {
        let cases: [([Decimal], Decimal)] = [
            ([], 0), ([5], 5), ([1, 3], 2), ([3, 1, 2], 2), ([4, 1, 3, 2], Decimal(string: "2.5")!),
            ([10, 10, 10, 10], 10), ([-5, 5], 0), ([Decimal(string: "0.1")!, Decimal(string: "0.3")!], Decimal(string: "0.2")!)
        ]
        for (values, expected) in cases {
            XCTAssertEqual(InsightStatistics.median(values), expected, "\(values)")
        }
    }

    func testMADTable() {
        let cases: [([Decimal], Decimal)] = [
            ([], 0), ([7], 0), ([1, 1, 1, 1], 0),
            ([1, 2, 3, 4, 5], 1),            // median 3, deviations 2 1 0 1 2 → 1
            ([1000, 1100, 900, 1000, 1050], 50),
            ([1, 2, 3, 4, 100], 1)           // one wild value barely moves MAD
        ]
        for (values, expected) in cases {
            XCTAssertEqual(InsightStatistics.mad(values), expected, "\(values)")
        }
    }

    func testBaselineScaleAndFloors() {
        let regular = InsightStatistics.baseline(of: [1000, 1100, 900, 1000, 1050])
        XCTAssertEqual(regular.median, 1000)
        XCTAssertEqual(regular.mad, 50)
        XCTAssertEqual(regular.scale, 100, "MAD·1.4826 = 74 is lifted to the 10% floor")
        XCTAssertEqual(regular.zScore(of: 1350), 3.5, accuracy: 1e-9)
        XCTAssertEqual(regular.zScore(of: 650), -3.5, accuracy: 1e-9)

        let identical = InsightStatistics.baseline(of: [200, 200, 200, 200])
        XCTAssertEqual(identical.mad, 0)
        XCTAssertEqual(identical.scale, 20, "perfectly regular history still gets a finite scale")

        let wide = InsightStatistics.baseline(of: [100, 300, 500, 700, 900])
        XCTAssertEqual(wide.median, 500)
        XCTAssertEqual(wide.mad, 200)
        XCTAssertEqual(NSDecimalNumber(decimal: wide.scale).doubleValue, 296.52, accuracy: 0.01)

        let zeros = InsightStatistics.baseline(of: [0, 0, 0], absoluteFloor: 5)
        XCTAssertEqual(zeros.scale, 5, "an all-zero history uses the absolute floor")

        XCTAssertEqual(InsightStatistics.baseline(of: []).zScore(of: 50), 0)
    }

    func testOutlierDoesNotInflateTheBaseline() {
        // A mean/standard deviation would swallow the 10,000; median/MAD does not.
        let baseline = InsightStatistics.baseline(of: [100, 110, 90, 105, 10_000])
        XCTAssertEqual(baseline.median, 105)
        XCTAssertLessThan(baseline.scale, 20)
        XCTAssertGreaterThan(baseline.zScore(of: 10_000), 100)
    }

    func testMerchantNormalizationTable() {
        let cases: [(String, String)] = [
            ("Netflix", "netflix"), ("NETFLIX.COM", "netflix"), ("netflix  #1234", "netflix"),
            ("  Wildflour Café ", "wildflour cafe"), ("7-Eleven", "eleven"), ("", ""), ("   ", ""),
            ("Grab* Ride", "grab ride"), ("com", "com"), ("Spotify Inc.", "spotify")
        ]
        for (name, expected) in cases {
            XCTAssertEqual(MerchantNormalizer.key(for: name), expected, "'\(name)'")
        }
    }

    // MARK: - Month-over-month change (now = 15 Nov 2026; compares 1–15 Nov with 1–15 Oct)

    private func changeEntries(dining current: Decimal, prior: Decimal = 1000, extraPrior: [LedgerEntry] = [], extraCurrent: [LedgerEntry] = []) -> [LedgerEntry] {
        [
            F.spend(prior, .dining, on: F.date(2026, 10, 5)),
            F.spend(1000, .groceries, on: F.date(2026, 10, 5)),
            F.spend(1000, .transport, on: F.date(2026, 10, 5)),
            F.spend(current, .dining, on: F.date(2026, 11, 5)),
            F.spend(1000, .groceries, on: F.date(2026, 11, 5)),
            F.spend(1000, .transport, on: F.date(2026, 11, 5))
        ] + extraPrior + extraCurrent
    }

    func testCategoryChangeThresholdTable() throws {
        struct Row {
            let current: Decimal
            let severity: Insight.Severity?
            let impact: Decimal
            let up: Bool
        }
        let rows = [
            Row(current: 1000, severity: nil, impact: 0, up: true),
            Row(current: 1100, severity: nil, impact: 0, up: true),     // +10%
            Row(current: 1240, severity: nil, impact: 0, up: true),     // +24%
            Row(current: 1250, severity: .notice, impact: 250, up: true),   // +25% = threshold
            Row(current: 1999, severity: .notice, impact: 999, up: true),
            Row(current: 2000, severity: .warning, impact: 1000, up: true), // doubled
            Row(current: 760, severity: nil, impact: 0, up: false),     // −24%
            Row(current: 750, severity: .info, impact: 250, up: false), // −25%
            Row(current: 100, severity: .info, impact: 900, up: false)
        ]
        for row in rows {
            let insights = F.run(now: F.date(2026, 11, 15), entries: changeEntries(dining: row.current))
            let change = insights.first(.categoryChange, category: .dining)
            if let severity = row.severity {
                let found = try XCTUnwrap(change, "dining \(row.current)")
                XCTAssertEqual(found.severity, severity, "dining \(row.current)")
                XCTAssertEqual(found.impactAmount, row.impact, "dining \(row.current)")
                XCTAssertEqual(found.title.contains("up"), row.up)
                XCTAssertEqual(found.id, "categoryChange:dining:2026-11")
            } else {
                XCTAssertNil(change, "dining \(row.current)")
            }
        }
        // Categories that did not move are never reported.
        let steady = F.run(now: F.date(2026, 11, 15), entries: changeEntries(dining: 2000))
        XCTAssertNil(steady.first(.categoryChange, category: .groceries))
    }

    func testSmallMovesAreIgnoredWhenTheyAreImmaterial() {
        // dining doubles 100 → 200 but the comparison period spent 6,000: +100 is 1.7% of it.
        let entries = [
            F.spend(100, .dining, on: F.date(2026, 10, 5)), F.spend(5900, .groceries, on: F.date(2026, 10, 5)),
            F.spend(200, .dining, on: F.date(2026, 11, 5)), F.spend(5900, .groceries, on: F.date(2026, 11, 5))
        ]
        XCTAssertNil(F.run(now: F.date(2026, 11, 15), entries: entries).first(.categoryChange))
    }

    func testNewCategoryIsReportedOnlyWhenMaterial() {
        let material = F.run(now: F.date(2026, 11, 15), entries: changeEntries(dining: 1000, extraCurrent: [F.spend(400, .travel, on: F.date(2026, 11, 6))]))
        let travel = material.first(.categoryChange, category: .travel)
        XCTAssertEqual(travel?.severity, .warning)
        XCTAssertEqual(travel?.impactAmount, 400)
        XCTAssertTrue(travel?.summary.contains("no spending") == true)

        let tiny = F.run(now: F.date(2026, 11, 15), entries: changeEntries(dining: 1000, extraCurrent: [F.spend(100, .travel, on: F.date(2026, 11, 6))]))
        XCTAssertNil(tiny.first(.categoryChange, category: .travel), "100 is 3% of 3,000")
    }

    func testComparisonUsesTheSameNumberOfDaysOnBothSides() throws {
        // On 15 Nov the prior window is 1–15 Oct: the 20 Oct purchase must not count.
        let entries = changeEntries(dining: 1500, extraPrior: [F.spend(9000, .dining, on: F.date(2026, 10, 20))])
        let change = try XCTUnwrap(F.run(now: F.date(2026, 11, 15), entries: entries).first(.categoryChange, category: .dining))
        XCTAssertDecimal(change.money("Same days last month"), 1000)
        XCTAssertDecimal(change.money("This month so far"), 1500)
    }

    func testComparisonWindowIsClampedToTheShorterPreviousMonth() throws {
        // 31 Mar vs February (28 days): the whole of February, not 31 days of it.
        let entries = [
            F.spend(1000, .dining, on: F.date(2026, 2, 27)),
            F.spend(1000, .groceries, on: F.date(2026, 2, 27)),
            F.spend(1500, .dining, on: F.date(2026, 3, 30)),
            F.spend(1000, .groceries, on: F.date(2026, 3, 30))
        ]
        let change = try XCTUnwrap(F.run(now: F.date(2026, 3, 31), entries: entries).first(.categoryChange, category: .dining))
        XCTAssertDecimal(change.money("Same days last month"), 1000)
        XCTAssertEqual(change.severity, .notice)
    }

    func testEarlyInTheMonthTheLastTwoCompleteMonthsAreCompared() throws {
        // 3 Nov is too early for month-to-date, so October is compared with September.
        let entries = [
            F.spend(1000, .dining, on: F.date(2026, 9, 12)), F.spend(1000, .groceries, on: F.date(2026, 9, 12)),
            F.spend(1500, .dining, on: F.date(2026, 10, 12)), F.spend(1000, .groceries, on: F.date(2026, 10, 12))
        ]
        let change = try XCTUnwrap(F.run(now: F.date(2026, 11, 3), entries: entries).first(.categoryChange, category: .dining))
        XCTAssertEqual(change.id, "categoryChange:dining:2026-10")
        XCTAssertDecimal(change.money("Last month"), 1500)
        XCTAssertDecimal(change.money("Month before"), 1000)
    }

    func testEarlyMonthAnomalyDoesNotHideLastMonthsChange() throws {
        // 3 Nov: the change compares October with September, the anomaly is about November.
        let entries = F.monthly(.shopping, amounts: [1000, 1000, 1000, 1600], endingBefore: 2026, 11)
            + F.monthly(.groceries, amounts: [2000, 2000, 2000, 2000], endingBefore: 2026, 11)
            + [F.spend(3000, .shopping, on: F.date(2026, 11, 2))]
        let insights = F.run(now: F.date(2026, 11, 3), entries: entries)
        XCTAssertNotNil(insights.first(.categoryAnomaly, category: .shopping))
        let change = try XCTUnwrap(insights.first(.categoryChange, category: .shopping))
        XCTAssertEqual(change.id, "categoryChange:shopping:2026-10")
    }

    func testMinimumElapsedDaysBoundary() {
        let entries = [
            F.spend(1000, .dining, on: F.date(2026, 10, 1)), F.spend(1000, .groceries, on: F.date(2026, 10, 1)),
            F.spend(2500, .dining, on: F.date(2026, 11, 1)), F.spend(1000, .groceries, on: F.date(2026, 11, 1))
        ]
        // Day 6: falls back to Sep/Oct (September is empty → nothing to compare).
        XCTAssertNil(F.run(now: F.date(2026, 11, 6), entries: entries).first(.categoryChange))
        // Day 7: month-to-date against the same 7 days of October.
        XCTAssertNotNil(F.run(now: F.date(2026, 11, 7), entries: entries).first(.categoryChange, category: .dining))
    }

    func testIncomeAndTransfersNeverCountAsSpendingChange() {
        let entries = changeEntries(dining: 1000, extraCurrent: [
            F.spend(9000, .dining, on: F.date(2026, 11, 6), kind: .income),
            F.spend(9000, .dining, on: F.date(2026, 11, 6), kind: .transfer),
            F.spend(9000, .savings, on: F.date(2026, 11, 6))
        ])
        XCTAssertTrue(F.run(now: F.date(2026, 11, 15), entries: entries).of(.categoryChange).isEmpty)
    }

    // MARK: - Category anomaly (history Jun–Oct, now = 30 Nov so month-to-date is the whole month)

    private let groceryHistory: [Decimal] = [1000, 1100, 900, 1000, 1050]

    private func anomalyEntries(current: Decimal, history: [Decimal]? = nil) -> [LedgerEntry] {
        F.monthly(.groceries, amounts: history ?? groceryHistory, endingBefore: 2026, 11)
            + [F.spend(current, .groceries, on: F.date(2026, 11, 12))]
    }

    func testCategoryAnomalyThresholdTable() throws {
        struct Row {
            let current: Decimal
            let severity: Insight.Severity?
        }
        // median 1000, scale 100 → z = (x − 1000) / 100
        let rows = [
            Row(current: 600, severity: nil), Row(current: 1000, severity: nil), Row(current: 1349, severity: nil),
            Row(current: 1350, severity: .notice),      // z = 3.5
            Row(current: 1699, severity: .notice),
            Row(current: 1700, severity: .warning),     // z = 7
            Row(current: 5000, severity: .warning)
        ]
        for row in rows {
            let insights = F.run(now: F.date(2026, 11, 30), entries: anomalyEntries(current: row.current))
            let anomaly = insights.first(.categoryAnomaly, category: .groceries)
            if let severity = row.severity {
                let found = try XCTUnwrap(anomaly, "current \(row.current)")
                XCTAssertEqual(found.severity, severity, "current \(row.current)")
                XCTAssertDecimal(found.impactAmount, row.current - 1000)
                XCTAssertDecimal(found.money("Typical month (median)"), 1000)
                XCTAssertDecimal(found.money("Typical variation (MAD)"), 50)
                // A category outlier already explains the jump, so it isn't also a "change" card.
                XCTAssertNil(insights.first(.categoryChange, category: .groceries), "current \(row.current)")
            } else {
                XCTAssertNil(anomaly, "current \(row.current)")
            }
        }
        // Just under the threshold the plain month-over-month card still fires (1349 vs 1050 is +28%).
        let near = F.run(now: F.date(2026, 11, 30), entries: anomalyEntries(current: 1349))
        XCTAssertNotNil(near.first(.categoryChange, category: .groceries))
    }

    func testCategoryAnomalyNeedsEnoughHistory() {
        let twoMonths = anomalyEntries(current: 5000, history: [1000, 1100])
        XCTAssertNil(F.run(now: F.date(2026, 11, 30), entries: twoMonths).first(.categoryAnomaly))
        let threeMonths = anomalyEntries(current: 5000, history: [1000, 1100, 900])
        XCTAssertNotNil(F.run(now: F.date(2026, 11, 30), entries: threeMonths).first(.categoryAnomaly))
    }

    func testPerfectlyRegularHistoryStillUsesAFiniteScale() throws {
        let flat = anomalyEntries(current: 1400, history: [1000, 1000, 1000, 1000, 1000])
        let anomaly = try XCTUnwrap(F.run(now: F.date(2026, 11, 30), entries: flat).first(.categoryAnomaly))
        XCTAssertEqual(anomaly.severity, .notice)   // z = 4
        XCTAssertNil(F.run(now: F.date(2026, 11, 30), entries: anomalyEntries(current: 1300, history: [1000, 1000, 1000, 1000, 1000])).first(.categoryAnomaly))
    }

    func testAnomalyBaselineIsLimitedToSixMonths() {
        // Seven months of history: the oldest (a huge 9,000 month) falls outside the 6-month window.
        let history: [Decimal] = [9000, 1000, 1100, 900, 1000, 1050, 1000]
        let entries = anomalyEntries(current: 1700, history: history)
        let anomaly = F.run(now: F.date(2026, 11, 30), entries: entries).first(.categoryAnomaly)
        XCTAssertEqual(anomaly?.severity, .warning)
        XCTAssertEqual(anomaly?.evidence.first { $0.label == "Months compared" }?.value, .count(6))
    }

    func testAnomalyBaselineNeverReachesBeforeTheFirstTransaction() {
        // Data starts in August, so only Aug–Oct (3 months) form the baseline, and zeros before that
        // are not invented.
        let entries = F.monthly(.groceries, amounts: [1000, 1100, 900], endingBefore: 2026, 11) + [F.spend(1700, .groceries, on: F.date(2026, 11, 12))]
        let anomaly = F.run(now: F.date(2026, 11, 30), entries: entries).first(.categoryAnomaly)
        XCTAssertEqual(anomaly?.evidence.first { $0.label == "Months compared" }?.value, .count(3))
    }

    func testMidMonthAnomalyIsJudgedOnTheProjectedMonth() throws {
        // 15 Nov: 700 spent in 15 days projects to 1,400 (z = 4); month-to-date alone (700) would look fine.
        let anomaly = try XCTUnwrap(F.run(now: F.date(2026, 11, 15), entries: anomalyEntries(current: 700)).first(.categoryAnomaly))
        XCTAssertDecimal(anomaly.money("Projected this month"), 1400)
        XCTAssertEqual(anomaly.severity, .notice)
    }

    func testEarlyMonthAnomalyUsesMonthToDateAsALowerBound() {
        // 3 Nov: no extrapolation, so 1,400 already spent in three days is flagged but 700 is not.
        XCTAssertNotNil(F.run(now: F.date(2026, 11, 3), entries: anomalyEntries(current: 1400).map { entry in
            entry.date > F.date(2026, 11, 1) ? LedgerEntry(amount: entry.amount, category: entry.category, date: F.date(2026, 11, 2)) : entry
        }).first(.categoryAnomaly))
        XCTAssertNil(F.run(now: F.date(2026, 11, 3), entries: anomalyEntries(current: 700).map { entry in
            entry.date > F.date(2026, 11, 1) ? LedgerEntry(amount: entry.amount, category: entry.category, date: F.date(2026, 11, 2)) : entry
        }).first(.categoryAnomaly))
    }

    func testRareCategoryJumpIsFlaggedAgainstTypicalTotalSpending() throws {
        // Travel is normally unused (median 0); 1,000 against ~3,000 of typical monthly spending is huge.
        let history = F.monthly(.groceries, amounts: [3000, 3000, 3000, 3000], endingBefore: 2026, 11)
        let entries = history + [F.spend(1000, .travel, on: F.date(2026, 11, 12))]
        let anomaly = try XCTUnwrap(F.run(now: F.date(2026, 11, 30), entries: entries).first(.categoryAnomaly, category: .travel))
        XCTAssertDecimal(anomaly.money("Typical month (median)"), 0)
        // A 50-unit blip is below the 5% materiality line.
        let blip = history + [F.spend(50, .travel, on: F.date(2026, 11, 12))]
        XCTAssertNil(F.run(now: F.date(2026, 11, 30), entries: blip).first(.categoryAnomaly, category: .travel))
    }

    // MARK: - Merchant anomaly

    /// "Cafe Luna" history on irregular days so it is not mistaken for a recurring charge.
    private func lunaHistory(amounts: [Decimal] = [100, 110, 90, 100, 105]) -> [LedgerEntry] {
        let days: [(Int, Int)] = [(6, 3), (7, 20), (8, 11), (9, 27), (10, 8)]
        return zip(amounts, days).map { amount, day in
            F.spend(amount, .dining, merchant: "Cafe Luna", on: F.date(2026, day.0, day.1))
        }
    }

    func testMerchantAnomalyThresholdTable() throws {
        struct Row {
            let amount: Decimal
            let severity: Insight.Severity?
        }
        // median 100, scale 10 (10% floor) → z = (x − 100) / 10, and it must also exceed 1.5 × median.
        let rows = [
            Row(amount: 100, severity: nil), Row(amount: 140, severity: nil),
            Row(amount: 150, severity: nil),            // z = 5 but exactly 1.5×, not above it
            Row(amount: 151, severity: .notice),
            Row(amount: 169, severity: .notice),
            Row(amount: 170, severity: .warning),       // z = 7
            Row(amount: 400, severity: .warning)
        ]
        for row in rows {
            let entries = lunaHistory() + [F.spend(row.amount, .dining, merchant: "Cafe Luna", on: F.date(2026, 11, 14))]
            let anomaly = F.run(now: F.date(2026, 11, 15), entries: entries).first(.merchantAnomaly)
            if let severity = row.severity {
                let found = try XCTUnwrap(anomaly, "amount \(row.amount)")
                XCTAssertEqual(found.severity, severity, "amount \(row.amount)")
                XCTAssertEqual(found.impactAmount, row.amount - 100)
                XCTAssertEqual(found.merchant, "Cafe Luna")
                XCTAssertEqual(found.id, "merchantAnomaly:cafe luna:2026-11-14")
                XCTAssertEqual(found.money("Usual charge (median)"), 100)
            } else {
                XCTAssertNil(anomaly, "amount \(row.amount)")
            }
        }
    }

    func testMerchantAnomalyNeedsAtLeastThreeEarlierCharges() {
        let two = Array(lunaHistory().prefix(2)) + [F.spend(900, .dining, merchant: "Cafe Luna", on: F.date(2026, 11, 14))]
        XCTAssertNil(F.run(now: F.date(2026, 11, 15), entries: two).first(.merchantAnomaly))
        let three = Array(lunaHistory().prefix(3)) + [F.spend(900, .dining, merchant: "Cafe Luna", on: F.date(2026, 11, 14))]
        XCTAssertNotNil(F.run(now: F.date(2026, 11, 15), entries: three).first(.merchantAnomaly))
    }

    func testMerchantNamesAreMatchedAfterNormalization() {
        let entries = lunaHistory() + [F.spend(400, .dining, merchant: "CAFE LUNA #12", on: F.date(2026, 11, 14))]
        XCTAssertNotNil(F.run(now: F.date(2026, 11, 15), entries: entries).first(.merchantAnomaly))
    }

    func testRecurringMerchantsAreLeftToThePriceCreepDetector() {
        // A subscription that suddenly costs twice as much is a price-creep matter, not a one-off outlier.
        let netflix = (0..<4).map { index in
            F.spend(720, .entertainment, merchant: "Netflix", on: F.date(2026, 7 + index, 10))
        } + [F.spend(1440, .entertainment, merchant: "Netflix", on: F.date(2026, 11, 10))]
        let insights = F.run(now: F.date(2026, 11, 15), entries: netflix)
        XCTAssertNil(insights.first(.merchantAnomaly))
        XCTAssertNotNil(insights.first(.priceCreep))
    }

    func testOnlyTheThreeBiggestMerchantAnomaliesAreKept() {
        var entries: [LedgerEntry] = []
        for (index, name) in ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].enumerated() {
            for (month, day) in [(6, 3), (7, 20), (8, 11), (9, 27), (10, 8)] {
                entries.append(F.spend(100, .shopping, merchant: name, on: F.date(2026, month, day)))
            }
            entries.append(F.spend(Decimal(500 + index * 100), .shopping, merchant: name, on: F.date(2026, 11, 12)))
        }
        let anomalies = F.run(now: F.date(2026, 11, 15), entries: entries).of(.merchantAnomaly)
        XCTAssertEqual(anomalies.count, 3)
        XCTAssertEqual(anomalies.compactMap(\.merchant).sorted(), ["Charlie", "Delta", "Echo"])
    }

    func testOnlyTheLargestOutlierPerMerchantIsReported() {
        let entries = lunaHistory() + [
            F.spend(300, .dining, merchant: "Cafe Luna", on: F.date(2026, 11, 5)),
            F.spend(500, .dining, merchant: "Cafe Luna", on: F.date(2026, 11, 9))
        ]
        let anomalies = F.run(now: F.date(2026, 11, 15), entries: entries).of(.merchantAnomaly)
        XCTAssertEqual(anomalies.count, 1)
        XCTAssertEqual(anomalies.first?.impactAmount, 400)
    }
}
