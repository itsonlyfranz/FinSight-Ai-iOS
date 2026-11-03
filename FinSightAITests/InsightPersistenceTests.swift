import SwiftData
import XCTest
@testable import FinSightAI

/// The engine wired to SwiftData: the trailing-month history window, persisted dismissals and snoozes, the
/// V2 → V3 migration, and the replacement trend string.
@MainActor
final class InsightPersistenceTests: XCTestCase {
    private typealias F = InsightFixtures
    private let utc = InsightFixtures.utc

    private func makeContainer() throws -> ModelContainer {
        try AppStoreSchema.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinSightInsights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("store.sqlite")
    }

    private func makeContext(_ container: ModelContainer, calendar: Calendar = InsightFixtures.utc) throws -> AppContext {
        let modelContext = ModelContext(container)
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(calendar: calendar),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: UnsupportedAIInsightService(reason: "test"),
            simulationService: DefaultSimulationService(),
            capabilityService: DefaultCapabilityService()
        )
        try context.bootstrap()
        return context
    }

    // MARK: - History window

    func testHistoryReturnsOnlyTheRequestedMonthsAndRespectsBoundaries() {
        let dates = [
            F.date(2026, 7, 31, hour: 23, minute: 59, second: 59),   // last instant before a 4-month window
            F.date(2026, 8, 1, hour: 0),                              // first instant of a 4-month window
            F.date(2026, 9, 15),
            F.date(2026, 10, 31, hour: 23, minute: 59, second: 59),
            F.date(2026, 11, 1, hour: 0),
            F.date(2026, 11, 30, hour: 23, minute: 59, second: 59),   // last instant of the window
            F.date(2026, 12, 1, hour: 0)                               // just after
        ]
        let records = dates.enumerated().map { index, date in
            TransactionRecord(amount: Decimal(index + 1), merchantName: "M\(index)", category: .other, date: date)
        }

        // Three months back from November is September–November: 1 Aug 00:00 is outside.
        let entries = LedgerEntry.history(from: records, now: F.date(2026, 11, 20), calendar: utc, months: 3)
        XCTAssertEqual(entries.map(\.amount).sorted(), [3, 4, 5, 6])
        // Four months reach back to exactly 1 Aug 00:00 but not to 31 Jul 23:59:59.
        let four = LedgerEntry.history(from: records, now: F.date(2026, 11, 20), calendar: utc, months: 4)
        XCTAssertEqual(four.map(\.amount).sorted(), [2, 3, 4, 5, 6])

        let single = LedgerEntry.history(from: records, now: F.date(2026, 11, 20), calendar: utc, months: 1)
        XCTAssertEqual(single.map(\.amount).sorted(), [5, 6])
    }

    func testHistoryUsesLocalMonthBoundariesAcrossDST() {
        let ny = F.newYork
        let records = [
            TransactionRecord(amount: 1, merchantName: "A", category: .other, date: F.date(2026, 2, 28, hour: 23, minute: 59, second: 59, in: ny)),
            TransactionRecord(amount: 2, merchantName: "B", category: .other, date: F.date(2026, 3, 1, hour: 0, in: ny)),
            TransactionRecord(amount: 3, merchantName: "C", category: .other, date: F.date(2026, 3, 8, hour: 3, minute: 30, in: ny)),
            TransactionRecord(amount: 4, merchantName: "D", category: .other, date: F.date(2026, 3, 31, hour: 23, minute: 59, second: 59, in: ny)),
            TransactionRecord(amount: 5, merchantName: "E", category: .other, date: F.date(2026, 4, 1, hour: 0, in: ny))
        ]

        let march = LedgerEntry.history(from: records, now: F.date(2026, 3, 15, in: ny), calendar: ny, months: 1)
        XCTAssertEqual(march.map(\.amount).sorted(), [2, 3, 4])
    }

    func testHistoryConvertsRecordsFaithfully() throws {
        let record = TransactionRecord(
            amount: F.dec("123.4567"), kind: .income, merchantName: "Employer", category: .bills, date: F.date(2026, 11, 2)
        )
        let entry = try XCTUnwrap(LedgerEntry.history(from: [record], now: F.date(2026, 11, 20), calendar: utc, months: 1).first)
        XCTAssertEqual(entry.amount, F.dec("123.4567"))
        XCTAssertEqual(entry.kind, .income)
        XCTAssertEqual(entry.merchant, "Employer")
        XCTAssertEqual(entry.category, .bills)
        XCTAssertTrue(entry.countsAsIncome)
        XCTAssertFalse(entry.countsAsSpending)
    }

    func testHistoryCoversTwelveMonthsByDefault() {
        let records = (0..<14).map { offset in
            TransactionRecord(amount: 1, merchantName: "M", category: .other, date: utc.date(byAdding: .month, value: -offset, to: F.date(2026, 11, 10))!)
        }
        let entries = LedgerEntry.history(from: records, now: F.date(2026, 11, 20), calendar: utc)
        XCTAssertEqual(entries.count, LedgerEntry.historyMonths)
    }

    func testAppContextInsightsUseTheInMemoryLedger() throws {
        let context = try makeContext(try makeContainer())
        context.modelContext.insert(Budget(category: .groceries, monthlyAmount: 1000))
        context.modelContext.insert(TransactionRecord(amount: 1400, merchantName: "", category: .groceries, date: F.date(2026, 11, 3)))
        try context.modelContext.save()
        try context.reloadPlanning(now: F.date(2026, 11, 15))
        XCTAssertTrue(context.engineInsights.of(.budgetBreach).isEmpty, "unloaded transactions are not analysed")

        try context.reloadTransactions()
        try context.reloadEngineInsights(now: F.date(2026, 11, 15))
        XCTAssertEqual(context.engineInsights.of(.budgetBreach).map(\.category), [.groceries])
    }

    // MARK: - AppContext wiring

    func testAppContextComputesInsightsFromBudgetsIncomeAndGoals() throws {
        let context = try makeContext(try makeContainer())
        let now = F.date(2026, 11, 15)
        context.modelContext.insert(Budget(category: .groceries, monthlyAmount: 1000))
        context.modelContext.insert(IncomeSource(name: "Salary", monthlyAmount: 10_000))
        let goal = SavingsGoal(name: "Emergency fund", targetAmount: 9000)
        context.modelContext.insert(goal)
        goal.contribute(3000, on: F.date(2026, 10, 1))
        for amount in [1000, 1000, 1000] as [Decimal] {
            context.modelContext.insert(TransactionRecord(amount: amount, merchantName: "", category: .bills, date: F.date(2026, 10, 10), note: ""))
        }
        context.modelContext.insert(TransactionRecord(amount: 1400, merchantName: "", category: .groceries, date: F.date(2026, 11, 3)))
        try context.modelContext.save()

        try context.reloadTransactions()
        try context.reloadEngineInsights(now: now)

        let kinds = Set(context.engineInsights.map(\.kind))
        XCTAssertTrue(kinds.contains(.budgetBreach), "\(kinds)")
        XCTAssertTrue(kinds.contains(.savingsRate), "\(kinds)")
        XCTAssertTrue(kinds.contains(.emergencyRunway), "\(kinds)")
        XCTAssertEqual(context.engineInsights.first?.kind, .budgetBreach, "ranked by severity")
    }

    func testDismissAndSnoozePersistAcrossRelaunch() throws {
        let url = try makeTemporaryStoreURL()
        let now = F.date(2026, 11, 15)
        var dismissedID = ""
        var snoozedID = ""
        do {
            let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
            let context = try makeContext(container)
            context.modelContext.insert(Budget(category: .groceries, monthlyAmount: 1000))
            context.modelContext.insert(Budget(category: .dining, monthlyAmount: 1000))
            context.modelContext.insert(TransactionRecord(amount: 1400, merchantName: "", category: .groceries, date: F.date(2026, 11, 3)))
            context.modelContext.insert(TransactionRecord(amount: 1400, merchantName: "", category: .dining, date: F.date(2026, 11, 3)))
            try context.modelContext.save()
            try context.reloadTransactions()
            try context.reloadEngineInsights(now: now)

            let breaches = context.engineInsights.of(.budgetBreach)
            XCTAssertEqual(breaches.count, 2)
            let dismissed = try XCTUnwrap(breaches.first { $0.category == .groceries })
            let snoozed = try XCTUnwrap(breaches.first { $0.category == .dining })
            dismissedID = dismissed.id
            snoozedID = snoozed.id

            try context.dismissInsight(dismissed, now: now)
            try context.snoozeInsight(snoozed, days: 7, now: now)
            XCTAssertNil(context.engineInsights.first { $0.id == dismissedID })
            XCTAssertNil(context.engineInsights.first { $0.id == snoozedID })
            XCTAssertEqual(context.hiddenInsightCount, 2)
        }

        // "Relaunch": a brand-new container and context over the same store file.
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
        let context = try makeContext(container)
        try context.reloadEngineInsights(now: now)
        XCTAssertNil(context.engineInsights.first { $0.id == dismissedID }, "dismissal survived the relaunch")
        XCTAssertNil(context.engineInsights.first { $0.id == snoozedID }, "snooze survived the relaunch")

        // Six days on the snooze still holds; after seven it has expired but the dismissal has not.
        try context.reloadEngineInsights(now: F.date(2026, 11, 21))
        XCTAssertNil(context.engineInsights.first { $0.id == snoozedID })
        let later = F.date(2026, 11, 22, hour: 12)
        try context.reloadEngineInsights(now: later)
        XCTAssertNil(context.engineInsights.first { $0.id == dismissedID })
        // The ids are scoped to November, so the engine at that date still produces the November dining
        // breach and the expired snooze lets it through.
        XCTAssertNotNil(context.engineInsights.first { $0.id == snoozedID })
    }

    func testRestoreHiddenInsightsBringsEverythingBack() throws {
        let context = try makeContext(try makeContainer())
        let now = F.date(2026, 11, 15)
        context.modelContext.insert(Budget(category: .groceries, monthlyAmount: 1000))
        context.modelContext.insert(TransactionRecord(amount: 1400, merchantName: "", category: .groceries, date: F.date(2026, 11, 3)))
        try context.modelContext.save()
        try context.reloadTransactions()
        try context.reloadEngineInsights(now: now)

        let all = context.engineInsights
        XCTAssertFalse(all.isEmpty)
        for insight in all { try context.dismissInsight(insight, now: now) }
        XCTAssertTrue(context.engineInsights.isEmpty)
        XCTAssertEqual(context.hiddenInsightCount, all.count)

        try context.restoreHiddenInsights(now: now)
        XCTAssertEqual(context.engineInsights, all)
        XCTAssertEqual(context.hiddenInsightCount, 0)
        XCTAssertTrue(try context.modelContext.fetch(FetchDescriptor<InsightStateRecord>()).isEmpty)
    }

    func testDismissingTwiceAndThenSnoozingKeepsOneRecord() throws {
        let context = try makeContext(try makeContainer())
        let now = F.date(2026, 11, 15)
        context.modelContext.insert(Budget(category: .groceries, monthlyAmount: 1000))
        context.modelContext.insert(TransactionRecord(amount: 1400, merchantName: "", category: .groceries, date: F.date(2026, 11, 3)))
        try context.modelContext.save()
        try context.reloadTransactions()
        try context.reloadEngineInsights(now: now)

        let insight = try XCTUnwrap(context.engineInsights.of(.budgetBreach).first)
        try context.dismissInsight(insight, now: now)
        try context.dismissInsight(insight, now: now)
        try context.snoozeInsight(insight, days: 3, now: now)
        let records = try context.modelContext.fetch(FetchDescriptor<InsightStateRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.status, .snoozed)
        XCTAssertEqual(records.first?.snoozedUntil, F.date(2026, 11, 18))
    }

    func testStoreIntegrityCollapsesDuplicateInsightStateRows() throws {
        let container = try makeContainer()
        let modelContext = ModelContext(container)
        modelContext.insert(InsightStateRecord(insightID: "x", status: .dismissed, updatedAt: F.date(2026, 1, 1)))
        modelContext.insert(InsightStateRecord(insightID: "x", status: .snoozed, snoozedUntil: F.date(2026, 2, 1), updatedAt: F.date(2026, 1, 2)))
        modelContext.insert(InsightStateRecord(insightID: "y", status: .dismissed))
        try modelContext.save()
        XCTAssertEqual(try StoreIntegrity.dedupe(in: modelContext), 1)
        let rows = try modelContext.fetch(FetchDescriptor<InsightStateRecord>(sortBy: [SortDescriptor(\.insightID)]))
        XCTAssertEqual(rows.map(\.insightID), ["x", "y"])
        XCTAssertEqual(rows.first?.status, .snoozed, "the most recently updated row wins")
    }

    func testSuppressionsLoaderSkipsUnknownStatuses() throws {
        let container = try makeContainer()
        let modelContext = ModelContext(container)
        let odd = InsightStateRecord(insightID: "odd", status: .dismissed)
        odd.statusRawValue = "from-the-future"
        modelContext.insert(odd)
        modelContext.insert(InsightStateRecord(insightID: "ok", status: .dismissed))
        try modelContext.save()
        XCTAssertEqual(try InsightDataLoader.suppressions(in: modelContext).map(\.insightID), ["ok"])
    }

    // MARK: - V2 → V3 migration

    func testStoreWrittenAsSchemaV2OpensAtV3WithAllDataIntact() throws {
        let url = try makeTemporaryStoreURL()
        let transactionID = UUID()
        do {
            let v2 = Schema(FinSightSchemaV2.models)
            let container = try ModelContainer(for: v2, configurations: ModelConfiguration(schema: v2, url: url))
            let context = ModelContext(container)
            context.insert(FinSightSchemaV2.TransactionRecord(
                id: transactionID, amount: F.dec("19.99"), merchantName: "Netflix", category: .entertainment, date: F.date(2026, 10, 10)
            ))
            context.insert(FinSightSchemaV2.Budget(category: .dining, monthlyAmount: 250))
            context.insert(FinSightSchemaV2.IncomeSource(name: "Salary", monthlyAmount: 4000))
            let goal = FinSightSchemaV2.SavingsGoal(name: "Emergency", targetAmount: 5000)
            context.insert(goal)
            goal.contribute(700)
            context.insert(FinSightSchemaV2.AppSettings(currencyCode: "EUR", firstWeekday: 2))
            try context.save()
        }

        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
        let context = ModelContext(container)
        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(transactions.map(\.id), [transactionID])
        XCTAssertEqual(transactions.first?.amount, F.dec("19.99"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Budget>()).first?.monthlyAmount, 250)
        XCTAssertEqual(try context.fetch(FetchDescriptor<IncomeSource>()).first?.monthlyAmount, 4000)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsGoal>()).first?.savedAmount, 700)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).first?.currencyCode, "EUR")
        XCTAssertTrue(try context.fetch(FetchDescriptor<InsightStateRecord>()).isEmpty)

        // The new table is usable straight away.
        context.insert(InsightStateRecord(insightID: "budgetBreach:dining:2026-10", status: .dismissed))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<InsightStateRecord>()).count, 1)
    }

    func testMigrationPlanListsEverySchemaInOrder() {
        XCTAssertEqual(FinSightMigrationPlan.schemas.count, 3)
        XCTAssertEqual(FinSightMigrationPlan.stages.count, 2)
        XCTAssertEqual(FinSightSchemaV3.models.count, FinSightSchemaV2.models.count + 1)
        XCTAssertEqual(FinSightSchemaV3.versionIdentifier, Schema.Version(3, 0, 0))
    }

    // MARK: - Trend string (replaces the invented one)

    func testSpendingTrendTable() {
        struct Row {
            let label: String
            let now: Date
            let entries: [LedgerEntry]
            let expected: String
        }
        func e(_ amount: Decimal, _ date: Date) -> LedgerEntry { F.spend(amount, .dining, on: date) }
        let rows = [
            Row(label: "empty", now: F.date(2026, 11, 15), entries: [], expected: SpendingTrend.emptyMessage),
            Row(label: "only income", now: F.date(2026, 11, 15), entries: [F.spend(100, .other, on: F.date(2026, 11, 2), kind: .income)], expected: SpendingTrend.emptyMessage),
            Row(label: "up 50%", now: F.date(2026, 11, 15), entries: [e(150, F.date(2026, 11, 5)), e(100, F.date(2026, 10, 5))], expected: "Spending is up 50% compared with the same days last month."),
            Row(label: "down 50%", now: F.date(2026, 11, 15), entries: [e(50, F.date(2026, 11, 5)), e(100, F.date(2026, 10, 5))], expected: "Spending is down 50% compared with the same days last month."),
            Row(label: "inside the 5% band", now: F.date(2026, 11, 15), entries: [e(104, F.date(2026, 11, 5)), e(100, F.date(2026, 10, 5))], expected: "Spending is about the same as the same days last month."),
            Row(label: "just outside the band", now: F.date(2026, 11, 15), entries: [e(106, F.date(2026, 11, 5)), e(100, F.date(2026, 10, 5))], expected: "Spending is up 6% compared with the same days last month."),
            Row(label: "no baseline", now: F.date(2026, 11, 15), entries: [e(100, F.date(2026, 11, 5))], expected: "No spending in the same days last month to compare against yet."),
            Row(label: "baseline only after the window", now: F.date(2026, 11, 15), entries: [e(100, F.date(2026, 11, 5)), e(900, F.date(2026, 10, 20))], expected: "No spending in the same days last month to compare against yet."),
            Row(label: "day one with a baseline and no spending", now: F.date(2026, 11, 1), entries: [e(100, F.date(2026, 10, 1, hour: 8)), e(10, F.date(2026, 9, 1))], expected: "Nothing spent yet this month."),
            Row(label: "day two across the month boundary", now: F.date(2026, 3, 2), entries: [e(900, F.date(2026, 3, 1)), e(100, F.date(2026, 2, 1))], expected: "Spending is up 800% compared with the same days last month."),
            Row(label: "31st vs a 30-day month uses all of it", now: F.date(2026, 12, 31), entries: [e(200, F.date(2026, 12, 20)), e(100, F.date(2026, 11, 30))], expected: "Spending is up 100% compared with the same days last month."),
            Row(label: "future entries ignored", now: F.date(2026, 11, 15), entries: [e(100, F.date(2026, 11, 5)), e(100, F.date(2026, 10, 5)), e(5000, F.date(2026, 11, 20))], expected: "Spending is about the same as the same days last month."),
            Row(label: "January looks back to December", now: F.date(2027, 1, 10), entries: [e(300, F.date(2027, 1, 4)), e(100, F.date(2026, 12, 4))], expected: "Spending is up 200% compared with the same days last month.")
        ]
        for row in rows {
            XCTAssertEqual(SpendingTrend.description(entries: row.entries, now: row.now, calendar: utc), row.expected, row.label)
        }
    }

    func testSummaryTrendComesFromTheLedgerNotAFixedString() {
        let now = F.date(2026, 11, 15)
        let service = DefaultSummaryService(calendar: utc)
        let higher = service.makeMonthlySummary(from: [
            TransactionRecord(amount: 300, merchantName: "A", category: .dining, date: F.date(2026, 11, 5)),
            TransactionRecord(amount: 100, merchantName: "B", category: .dining, date: F.date(2026, 10, 5))
        ], now: now)
        let lower = service.makeMonthlySummary(from: [
            TransactionRecord(amount: 50, merchantName: "A", category: .dining, date: F.date(2026, 11, 5)),
            TransactionRecord(amount: 100, merchantName: "B", category: .dining, date: F.date(2026, 10, 5))
        ], now: now)
        XCTAssertEqual(higher.spendingTrendDescription, "Spending is up 200% compared with the same days last month.")
        XCTAssertEqual(lower.spendingTrendDescription, "Spending is down 50% compared with the same days last month.")
        XCTAssertNotEqual(AIFingerprint.monthlyInsights(summary: higher), AIFingerprint.monthlyInsights(summary: lower))
    }
}
