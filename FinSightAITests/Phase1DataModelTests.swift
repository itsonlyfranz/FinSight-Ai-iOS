import SwiftData
import XCTest
@testable import FinSightAI

/// Phase 1: exact money, transaction kinds, the V2 schema and the V1 → V2 migration.
@MainActor
final class Phase1DataModelTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    // MARK: - Decimal money

    func testDecimalMathIsExactWhereDoubleIsNot() {
        XCTAssertNotEqual(0.1 + 0.2, 0.3 as Double)
        let tenth = Decimal(string: "0.1")!, fifth = Decimal(string: "0.2")!, threeTenths = Decimal(string: "0.3")!
        XCTAssertEqual(tenth + fifth, threeTenths)

        let sum = (0..<10).map { _ in tenth }.sum()
        XCTAssertEqual(sum, 1)
    }

    func testScaledStorageRoundTripsExactly() {
        for text in ["0", "0.01", "0.1", "19.99", "1234567.8901", "-42.5"] {
            let value = Decimal(string: text)!
            XCTAssertEqual(Money.decimal(fromScaled: Money.scaled(value)), value, text)
        }
        XCTAssertEqual(Money.scaled(Decimal(string: "19.99")!), 199_900)
    }

    func testScaledStorageRoundsBeyondScaleAndClamps() {
        XCTAssertEqual(Money.decimal(fromScaled: Money.scaled(Decimal(string: "1.23456")!)), Decimal(string: "1.2346")!)
        XCTAssertEqual(Money.decimal(fromScaled: Money.scaled(Decimal(string: "1.23454")!)), Decimal(string: "1.2345")!)
        XCTAssertEqual(Money.decimal(fromScaled: Money.scaled(Decimal.greatestFiniteMagnitude)), Money.maximumMagnitude)
        XCTAssertEqual(Money.scaled(Decimal.nan), 0)
    }

    func testLegacyDoubleConvertsToItsDecimalRepresentation() {
        XCTAssertEqual(Money.decimal(fromLegacy: 0.1), Decimal(string: "0.1")!)
        XCTAssertEqual(Money.decimal(fromLegacy: 19.99), Decimal(string: "19.99")!)
        XCTAssertEqual(Money.scaled(fromLegacy: 3150), 31_500_000)
        XCTAssertEqual(Money.decimal(fromLegacy: .infinity), 0)
    }

    func testRecordsPersistAmountsExactly() throws {
        let context = try makeInMemoryContext()
        for _ in 0..<10 {
            context.insert(TransactionRecord(amount: Decimal(string: "0.1")!, merchantName: "Gum", category: .other, date: date(2024, 3, 1)))
        }
        try context.save()

        let records = try context.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(records.map(\.amount).sum(), 1)
        XCTAssertEqual(records.first?.amountScaled, 1_000)
    }

    func testAmountParserReturnsExactDecimal() {
        XCTAssertEqual(AmountParser.parse("0.1", locale: Locale(identifier: "en_US")), Decimal(string: "0.1"))
        XCTAssertEqual(AmountParser.parse("1,234.56", locale: Locale(identifier: "en_US")), Decimal(string: "1234.56"))
        XCTAssertEqual(AmountParser.parse("12,5", locale: Locale(identifier: "de_DE")), Decimal(string: "12.5"))
    }

    func testRepositoryRejectsOutOfRangeAmounts() {
        XCTAssertThrowsError(try ValidationError.validatedAmount(Money.maximumMagnitude + 1))
        XCTAssertThrowsError(try ValidationError.validatedAmount(-5))
        XCTAssertThrowsError(try ValidationError.validatedAmount(nil))
        XCTAssertNoThrow(try ValidationError.validatedAmount(Decimal(string: "0.0001")))
    }

    func testSummaryTotalsAreSummedExactly() {
        let now = date(2024, 3, 15)
        let transactions = (0..<10).map { _ in
            TransactionRecord(amount: Decimal(string: "0.1")!, merchantName: "Gum", category: .other, date: date(2024, 3, 2))
        }
        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, recurringSummary: .empty, now: now)
        XCTAssertEqual(summary.totalSpent, 1.0)
        XCTAssertEqual(summary.oneOffSpent, 1.0)
    }

    // MARK: - Transaction kind semantics

    func testSignedAmountSemantics() {
        let amount = Decimal(string: "250.75")!
        XCTAssertEqual(TransactionKind.expense.signedAmount(for: amount), -amount)
        XCTAssertEqual(TransactionKind.income.signedAmount(for: amount), amount)
        XCTAssertEqual(TransactionKind.transfer.signedAmount(for: amount), 0)

        let expense = TransactionRecord(amount: amount, kind: .expense, category: .dining, date: .now)
        let income = TransactionRecord(amount: amount, kind: .income, category: .other, date: .now)
        let transfer = TransactionRecord(amount: amount, kind: .transfer, category: .savings, date: .now)
        XCTAssertEqual(expense.signedAmount, -amount)
        XCTAssertEqual(income.signedAmount, amount)
        XCTAssertEqual(transfer.signedAmount, 0)
        XCTAssertEqual(expense.amount, amount, "stored amount is always the non-negative magnitude")
        XCTAssertEqual(income.amount, amount)
    }

    func testOnlyExpensesOutsideSavingsCountAsSpending() {
        func record(_ kind: TransactionKind, _ category: SpendingCategory) -> TransactionRecord {
            TransactionRecord(amount: 10, kind: kind, category: category, date: .now)
        }
        XCTAssertTrue(record(.expense, .dining).countsAsSpending)
        XCTAssertFalse(record(.expense, .savings).countsAsSpending)
        XCTAssertFalse(record(.income, .other).countsAsSpending)
        XCTAssertFalse(record(.transfer, .other).countsAsSpending)
        XCTAssertTrue(record(.income, .other).countsAsIncome)
        XCTAssertFalse(record(.expense, .other).countsAsIncome)
    }

    func testIncomeAndTransfersAreExcludedFromSpendingSummary() {
        let now = date(2024, 3, 15)
        let transactions = [
            TransactionRecord(amount: 100, merchantName: "Cafe", category: .dining, date: date(2024, 3, 3)),
            TransactionRecord(amount: 5_000, kind: .income, merchantName: "Employer", category: .other, date: date(2024, 3, 1)),
            TransactionRecord(amount: 700, kind: .transfer, merchantName: "Own account", category: .other, date: date(2024, 3, 2))
        ]
        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, recurringSummary: .empty, now: now)
        XCTAssertEqual(summary.totalSpent, 100)
        XCTAssertEqual(summary.transactionCount, 1)

        let runRate = MonthlyRunRate.estimate(from: transactions, now: now, calendar: calendar)
        XCTAssertEqual(runRate, 100.0 / 13.0 * 30.0, accuracy: 0.001)
    }

    func testKindPersistsAndUnknownRawValueFallsBackToExpense() throws {
        let context = try makeInMemoryContext()
        context.insert(TransactionRecord(amount: 5, kind: .income, category: .other, date: .now))
        try context.save()
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<TransactionRecord>()).first)
        XCTAssertEqual(record.kind, .income)
        record.kindRawValue = "future-kind"
        XCTAssertEqual(record.kind, .expense)
    }

    func testDraftCarriesKindThroughRepository() throws {
        let context = try makeInMemoryContext()
        let repository = SwiftDataTransactionRepository(modelContext: context)
        var draft = TransactionDraft()
        draft.locale = Locale(identifier: "en_US")
        draft.amountText = "2,500.50"
        draft.merchantName = "Employer"
        draft.kind = .income
        try repository.addTransaction(from: draft)

        let record = try XCTUnwrap(repository.fetchAllTransactions().first)
        XCTAssertEqual(record.kind, .income)
        XCTAssertEqual(record.amount, Decimal(string: "2500.5"))
        XCTAssertEqual(TransactionDraft(record: record).kind, .income)
    }

    // MARK: - New models

    func testBudgetIncomeAndGoalRoundTrip() throws {
        let context = try makeInMemoryContext()
        context.insert(IncomeSource(name: "Salary", monthlyAmount: Decimal(string: "45000.50")!))
        context.insert(Budget(category: .groceries, monthlyAmount: 8_000, rolloverEnabled: true))
        let goal = SavingsGoal(name: "Emergency fund", targetAmount: 100_000, targetDate: date(2025, 1, 1))
        context.insert(goal)
        goal.contribute(Decimal(string: "2500.25")!, on: date(2024, 3, 1), note: "first")
        goal.contribute(Decimal(string: "-500.25")!, on: date(2024, 3, 5), note: "withdrawal")
        try context.save()

        let income = try XCTUnwrap(context.fetch(FetchDescriptor<IncomeSource>()).first)
        XCTAssertEqual(income.monthlyAmount, Decimal(string: "45000.5"))
        XCTAssertTrue(income.isActive)

        let budget = try XCTUnwrap(context.fetch(FetchDescriptor<Budget>()).first)
        XCTAssertEqual(budget.category, .groceries)
        XCTAssertEqual(budget.monthlyAmount, 8_000)
        XCTAssertTrue(budget.rolloverEnabled)

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<SavingsGoal>()).first)
        XCTAssertEqual(stored.savedAmount, 2_000)
        XCTAssertEqual(stored.remainingAmount, 98_000)
        XCTAssertEqual(stored.progress, 0.02, accuracy: 0.0001)
        XCTAssertFalse(stored.isReached)
        XCTAssertEqual(stored.contributions?.count, 2)
        XCTAssertEqual(stored.contributions?.map(\.amount).sum(), stored.savedAmount)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GoalContribution>()).count, 2)

        context.delete(stored)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<GoalContribution>()).count, 0, "contributions cascade with their goal")
    }

    func testGoalIsReachedAndProgressClamps() {
        let goal = SavingsGoal(name: "Trip", targetAmount: 1_000)
        goal.contribute(1_500)
        XCTAssertTrue(goal.isReached)
        XCTAssertEqual(goal.progress, 1)
        XCTAssertEqual(goal.remainingAmount, 0)
        XCTAssertEqual(SavingsGoal(name: "No target", targetAmount: 0).progress, 0)
    }

    func testSettingsDefaultToDeviceRegion() throws {
        let ph = AppSettings.makeDefault(locale: Locale(identifier: "en_PH"), calendar: calendar)
        XCTAssertEqual(ph.currencyCode, "PHP")
        XCTAssertFalse(ph.hasCompletedOnboarding)
        XCTAssertEqual(ph.firstWeekday, calendar.firstWeekday)

        var monday = Calendar(identifier: .gregorian)
        monday.firstWeekday = 2
        XCTAssertEqual(AppSettings.makeDefault(locale: Locale(identifier: "de_DE"), calendar: monday).firstWeekday, 2)
        XCTAssertEqual(AppSettings.makeDefault(locale: Locale(identifier: "de_DE"), calendar: monday).currencyCode, "EUR")
    }

    func testSettingsSanitizeInputsAndApplyFirstWeekday() {
        let settings = AppSettings(currencyCode: " eur ", firstWeekday: 9)
        XCTAssertEqual(settings.currencyCode, "EUR")
        XCTAssertEqual(settings.firstWeekday, 1)
        XCTAssertEqual(AppSettings(currencyCode: "nope!", firstWeekday: 2).currencyCode, "USD")
        settings.firstWeekday = 2
        XCTAssertEqual(settings.calendar(basedOn: calendar).firstWeekday, 2)
    }

    func testBootstrapCreatesSettingsOnceAndLeavesLedgerEmpty() throws {
        let context = try makeInMemoryContext()
        let first = try AppSettings.fetchOrCreate(in: context, locale: Locale(identifier: "en_PH"))
        let second = try AppSettings.fetchOrCreate(in: context, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.currencyCode, "PHP", "an existing choice is never overwritten by the device locale")
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TransactionRecord>()).isEmpty)
    }

    // MARK: - CloudKit compatibility and app-level dedupe

    func testSchemaHasNoUniqueConstraints() {
        let schema = AppStoreSchema.schema
        XCTAssertEqual(schema.entities.count, 9)
        for entity in schema.entities {
            XCTAssertTrue(entity.uniquenessConstraints.isEmpty, "\(entity.name) must not declare .unique (CloudKit)")
            XCTAssertTrue(entity.properties.allSatisfy { !$0.isUnique }, "\(entity.name)")
        }
    }

    func testDedupeCollapsesDuplicatesKeepingNewest() throws {
        let context = try makeInMemoryContext()
        let id = UUID()
        let old = TransactionRecord(id: id, amount: 1, merchantName: "Old", category: .other, date: .now, updatedAt: date(2024, 1, 1))
        let new = TransactionRecord(id: id, amount: 2, merchantName: "New", category: .other, date: .now, updatedAt: date(2024, 2, 1))
        context.insert(old)
        context.insert(new)
        context.insert(TransactionRecord(amount: 3, merchantName: "Other", category: .other, date: .now))

        context.insert(Budget(category: .dining, monthlyAmount: 100, updatedAt: date(2024, 1, 1)))
        context.insert(Budget(category: .dining, monthlyAmount: 200, updatedAt: date(2024, 2, 1)))
        context.insert(Budget(category: .bills, monthlyAmount: 300))

        for key in ["a", "a", "b"] {
            context.insert(AIResponseCacheRecord(cacheKey: key, feature: .monthlyInsights, sourceFingerprint: "", payload: "", generatedAt: .now, providerIdentifier: "t"))
        }
        context.insert(AppSettings(currencyCode: "USD", firstWeekday: 1, updatedAt: date(2024, 1, 1)))
        context.insert(AppSettings(currencyCode: "PHP", firstWeekday: 2, updatedAt: date(2024, 2, 1)))
        try context.save()

        XCTAssertEqual(try StoreIntegrity.dedupe(in: context), 4)

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions.first { $0.id == id }?.merchantName, "New")
        let budgets = try context.fetch(FetchDescriptor<Budget>())
        XCTAssertEqual(budgets.count, 2)
        XCTAssertEqual(budgets.first { $0.category == .dining }?.monthlyAmount, 200)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AIResponseCacheRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).map(\.currencyCode), ["PHP"])

        XCTAssertEqual(try StoreIntegrity.dedupe(in: context), 0, "idempotent")
    }

    func testAppContextBootstrapDedupesAndLoadsSettings() throws {
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: UnsupportedAIInsightService(reason: "test"),
            simulationService: DefaultSimulationService(),
            capabilityService: DefaultCapabilityService()
        )
        modelContext.insert(Budget(category: .dining, monthlyAmount: 1))
        modelContext.insert(Budget(category: .dining, monthlyAmount: 2))
        try modelContext.save()

        try context.bootstrap()
        XCTAssertNotNil(context.settings)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<Budget>()).count, 1)
        XCTAssertTrue(context.transactions.isEmpty)
    }

    // MARK: - V1 → V2 migration

    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinSightMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("store.sqlite")
    }

    private struct V1Fixture {
        let transactionIDs: [UUID]
        let recurringID: UUID
    }

    /// Writes a genuine V1 store (the pre-versioning schema, Double amounts, `.unique` ids) to disk.
    private func writeV1Store(at url: URL) throws -> V1Fixture {
        let schema = Schema(FinSightSchemaV1.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = ModelContext(container)

        let amounts: [Double] = [0.1, 19.99, 3150, 1234.56, 0.07, 98765.43]
        var ids: [UUID] = []
        for (index, amount) in amounts.enumerated() {
            let id = UUID()
            ids.append(id)
            context.insert(FinSightSchemaV1.TransactionRecord(
                id: id,
                amount: amount,
                merchantName: "Merchant \(index)",
                category: SpendingCategory.allCases[index % SpendingCategory.allCases.count],
                date: date(2024, 3, index + 1),
                note: "note \(index)",
                createdAt: date(2024, 3, 1),
                updatedAt: date(2024, 3, 2)
            ))
        }
        let recurringID = UUID()
        context.insert(FinSightSchemaV1.RecurringExpenseRecord(
            id: recurringID, merchantName: "Netflix", amount: 719.99, category: .entertainment, expectedDay: 14, isActive: false, note: "streaming"
        ))
        context.insert(FinSightSchemaV1.AIResponseCacheRecord(
            cacheKey: "k1", feature: .monthlyInsights, sourceFingerprint: "fp", payload: "{}", generatedAt: date(2024, 3, 3),
            lastAutoRefreshDayKey: "2024-03-03", providerIdentifier: "test", failureMessage: "oops"
        ))
        try context.save()
        return V1Fixture(transactionIDs: ids, recurringID: recurringID)
    }

    func testMigrationFromV1PreservesEveryRecordAndAmountExactly() throws {
        let url = try makeTemporaryStoreURL()
        let fixture = try writeV1Store(at: url)

        let v2Schema = AppStoreSchema.schema
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: v2Schema, url: url))
        let context = ModelContext(container)

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>(sortBy: [SortDescriptor(\.date)]))
        XCTAssertEqual(transactions.count, 6, "no transaction lost")
        XCTAssertEqual(Set(transactions.map(\.id)), Set(fixture.transactionIDs))

        let expected = ["0.1", "19.99", "3150", "1234.56", "0.07", "98765.43"].map { Decimal(string: $0)! }
        XCTAssertEqual(transactions.map(\.amount), expected, "amounts migrate exactly, with no Double artefacts")
        XCTAssertEqual(transactions.map(\.merchantName), (0..<6).map { "Merchant \($0)" })
        XCTAssertEqual(transactions.map(\.note), (0..<6).map { "note \($0)" })
        XCTAssertTrue(transactions.allSatisfy { $0.kind == .expense }, "legacy rows were all expenses")
        XCTAssertEqual(transactions[0].createdAt, date(2024, 3, 1))
        XCTAssertEqual(transactions[0].updatedAt, date(2024, 3, 2))
        XCTAssertEqual(transactions[0].category, SpendingCategory.allCases[0])
        XCTAssertEqual(transactions[2].date, date(2024, 3, 3))

        let recurring = try XCTUnwrap(context.fetch(FetchDescriptor<RecurringExpenseRecord>()).first)
        XCTAssertEqual(recurring.id, fixture.recurringID)
        XCTAssertEqual(recurring.amount, Decimal(string: "719.99"))
        XCTAssertEqual(recurring.merchantName, "Netflix")
        XCTAssertEqual(recurring.expectedDay, 14)
        XCTAssertFalse(recurring.isActive)
        XCTAssertEqual(recurring.category, .entertainment)

        let cache = try XCTUnwrap(context.fetch(FetchDescriptor<AIResponseCacheRecord>()).first)
        XCTAssertEqual(cache.cacheKey, "k1")
        XCTAssertEqual(cache.sourceFingerprint, "fp")
        XCTAssertEqual(cache.lastAutoRefreshDayKey, "2024-03-03")
        XCTAssertEqual(cache.failureMessage, "oops")

        // New V2 entities start empty and are usable.
        XCTAssertTrue(try context.fetch(FetchDescriptor<Budget>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SavingsGoal>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<IncomeSource>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AppSettings>()).isEmpty)
        context.insert(Budget(category: .dining, monthlyAmount: 500))
        try context.save()
    }

    func testMigratedStoreIsStableOnReopenAndSummariesWork() throws {
        let url = try makeTemporaryStoreURL()
        _ = try writeV1Store(at: url)

        do {
            let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
            XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TransactionRecord>()).count, 6)
        }
        // Second open must not re-run the migration or alter amounts.
        let reopened = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
        let context = ModelContext(reopened)
        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(transactions.count, 6)
        XCTAssertEqual(transactions.map(\.amount).sum(), Decimal(string: "103170.15")!)

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(
            from: transactions, recurringSummary: .empty, now: date(2024, 3, 15)
        )
        XCTAssertEqual(summary.transactionCount, 6)
        XCTAssertEqual(summary.totalSpent, 103_170.15, accuracy: 0.0001)
    }

    func testMigrationOfEmptyV1StoreSucceeds() throws {
        let url = try makeTemporaryStoreURL()
        let schema = Schema(FinSightSchemaV1.models)
        do {
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            try ModelContext(container).save()
        }
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
        XCTAssertTrue(try ModelContext(container).fetch(FetchDescriptor<TransactionRecord>()).isEmpty)
    }
}
