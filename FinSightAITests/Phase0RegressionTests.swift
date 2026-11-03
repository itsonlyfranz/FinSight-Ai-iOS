import SwiftData
import XCTest
@testable import FinSightAI

/// Regression tests for the Phase 0 audit defects (D1-D9).
@MainActor
final class Phase0RegressionTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - Helpers

    private struct Harness {
        let context: AppContext
        let modelContext: ModelContext
        let ai: CountingAIService
    }

    private func makeHarness() throws -> Harness {
        let container = try ModelContainer(
            for: AppStoreSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let modelContext = ModelContext(container)
        let ai = CountingAIService()
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: ai,
            simulationService: DefaultSimulationService(),
            capabilityService: DefaultCapabilityService()
        )
        return Harness(context: context, modelContext: modelContext, ai: ai)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    private func addTransaction(_ context: AppContext, amount: String, merchant: String = "Cafe", category: SpendingCategory = .dining) throws {
        var draft = TransactionDraft()
        draft.locale = Locale(identifier: "en_US")
        draft.amountText = amount
        draft.merchantName = merchant
        draft.category = category
        context.activeDraft = draft
        try context.saveDraft()
    }

    // MARK: - D1 sample data is opt-in and never re-seeds

    func testD1_BootstrapLeavesEmptyLedgerEmpty() throws {
        let harness = try makeHarness()
        try harness.context.bootstrap()

        XCTAssertTrue(harness.context.transactions.isEmpty)
        XCTAssertTrue(harness.context.hasNoData)
    }

    func testD1_LoadSampleDataIsExplicitAndIdempotent() throws {
        let harness = try makeHarness()
        try harness.context.bootstrap()
        try harness.context.loadSampleData()
        let loaded = harness.context.transactions.count

        XCTAssertEqual(loaded, SampleData.makeTransactions().count)

        try harness.context.loadSampleData()
        XCTAssertEqual(harness.context.transactions.count, loaded)
    }

    func testD1_DeletingEverythingDoesNotBringSampleDataBack() throws {
        let harness = try makeHarness()
        try harness.context.loadSampleData()
        for transaction in harness.context.transactions {
            try harness.context.delete(transaction)
        }
        XCTAssertTrue(harness.context.transactions.isEmpty)

        // A relaunch runs bootstrap again on the now-empty ledger.
        try harness.context.bootstrap()

        XCTAssertTrue(harness.context.transactions.isEmpty)
    }

    // MARK: - D2 inactive recurring expenses stay reachable

    func testD2_InactiveRecurringExpenseCanBeReactivatedAndDeleted() throws {
        let harness = try makeHarness()
        var draft = RecurringExpenseDraft()
        draft.locale = Locale(identifier: "en_US")
        draft.merchantName = "Gym"
        draft.amountText = "40"
        draft.isActive = false
        harness.context.activeRecurringDraft = draft
        try harness.context.saveRecurringDraft()

        XCTAssertTrue(harness.context.recurringSummary.items.isEmpty)
        XCTAssertEqual(harness.context.recurringSummary.inactiveItems.map(\.merchantName), ["Gym"])
        XCTAssertTrue(harness.context.recurringSummary.hasAnyItems)

        let record = try XCTUnwrap(harness.context.recurringExpenses.first)
        try harness.context.setRecurringExpense(record, active: true)
        XCTAssertEqual(harness.context.recurringSummary.items.map(\.merchantName), ["Gym"])
        XCTAssertTrue(harness.context.recurringSummary.inactiveItems.isEmpty)

        try harness.context.setRecurringExpense(record, active: false)
        try harness.context.delete(record)
        XCTAssertFalse(harness.context.recurringSummary.hasAnyItems)
    }

    // MARK: - D3 store failures are recoverable

    func testD3_UnopenableStoreThrowsInsteadOfCrashing() {
        let unwritable = URL(fileURLWithPath: "/nonexistent-root/FinSight/default.store")

        XCTAssertThrowsError(try AppEnvironment.make(configuration: ModelConfiguration(url: unwritable)))
    }

    func testD3_StoreBackupMovesFilesAsideWithoutDeletingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        for suffix in ["", "-wal", "-shm"] {
            try Data("data\(suffix)".utf8).write(to: URL(fileURLWithPath: store.path + suffix))
        }

        let backup = try StoreBackup.moveStoreAside(storeURL: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(name).path), name)
        }
    }

    // MARK: - D4 trend uses last 7 vs prior 7 days across all transactions

    func testD4_TrendComparesTrailingWeeksAcrossMonthBoundary() {
        // 2 March: both comparison weeks (16-22 Feb and 23 Feb-1 Mar+) fall mostly in February.
        let now = date(2024, 3, 2)
        let transactions = [
            TransactionRecord(amount: 900, merchantName: "A", category: .dining, date: date(2024, 3, 1)),
            TransactionRecord(amount: 100, merchantName: "B", category: .dining, date: date(2024, 2, 20))
        ]

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, now: now)

        XCTAssertEqual(summary.spendingTrendDescription, "Your last 7 days are trending higher than the 7 days before.")
    }

    func testD4_TrendDetectsLowerSpendingAndMissingBaseline() {
        let now = date(2024, 3, 20)
        let service = DefaultSummaryService(calendar: calendar)

        let lower = service.makeMonthlySummary(
            from: [
                TransactionRecord(amount: 100, merchantName: "A", category: .dining, date: date(2024, 3, 19)),
                TransactionRecord(amount: 900, merchantName: "B", category: .dining, date: date(2024, 3, 10))
            ],
            now: now
        )
        let noBaseline = service.makeMonthlySummary(
            from: [TransactionRecord(amount: 100, merchantName: "A", category: .dining, date: date(2024, 3, 19))],
            now: now
        )

        XCTAssertEqual(lower.spendingTrendDescription, "Your last 7 days are trending lower than the 7 days before.")
        XCTAssertEqual(noBaseline.spendingTrendDescription, "Not enough spending in the previous 7 days yet to compare against.")
    }

    // MARK: - D5 insights refresh when data changes

    func testD5_InsightsRegenerateWhenDataChanges() async throws {
        let harness = try makeHarness()
        try addTransaction(harness.context, amount: "100")
        let firstFingerprint = harness.context.insightsFingerprint

        await harness.context.loadInsights()
        XCTAssertEqual(harness.ai.insightCalls, 1)

        // Same data, same day: served from cache.
        await harness.context.loadInsights()
        XCTAssertEqual(harness.ai.insightCalls, 1)

        try addTransaction(harness.context, amount: "250", merchant: "Bistro")
        XCTAssertNotEqual(harness.context.insightsFingerprint, firstFingerprint)

        await harness.context.loadInsights()
        XCTAssertEqual(harness.ai.insightCalls, 2)
    }

    func testD5_EmptyLedgerDoesNotCallTheModel() async throws {
        let harness = try makeHarness()

        await harness.context.loadInsights()

        XCTAssertEqual(harness.ai.insightCalls, 0)
        XCTAssertEqual(harness.context.insightState, .empty)
    }

    // MARK: - D6 simulation cache is keyed per scenario

    func testD6_EachScenarioGetsItsOwnCachedExplanation() async throws {
        let harness = try makeHarness()
        let scenarioA = SimulationInput(monthlyRunRate: 10_000, dailySavings: 100, reductionPercent: 10, savingsGoal: 20_000)
        let scenarioB = SimulationInput(monthlyRunRate: 10_000, dailySavings: 200, reductionPercent: 10, savingsGoal: 20_000)

        await harness.context.loadSimulationExplanation(input: scenarioA)
        await harness.context.loadSimulationExplanation(input: scenarioB)
        let records = try harness.modelContext.fetch(FetchDescriptor<AIResponseCacheRecord>())
        XCTAssertEqual(Set(records.map(\.cacheKey)).count, 2)

        // Back to A: shows A's own text from cache without another model call.
        await harness.context.loadSimulationExplanation(input: scenarioA)
        XCTAssertEqual(harness.ai.simulationCalls, 2)
        guard case .available(let content) = harness.context.simulatorExplanationState else {
            return XCTFail("Expected cached explanation")
        }
        let projectionA = DefaultSimulationService().project(input: scenarioA)
        XCTAssertEqual(content.value, "Explanation for \(projectionA.monthlySavings)")
    }

    func testD6_NewScenarioDoesNotShowAnotherScenariosText() async throws {
        let harness = try makeHarness()
        let scenarioA = SimulationInput(monthlyRunRate: 10_000, dailySavings: 100, reductionPercent: 10, savingsGoal: 20_000)
        await harness.context.loadSimulationExplanation(input: scenarioA)

        harness.ai.failSimulation = true
        let scenarioB = SimulationInput(monthlyRunRate: 10_000, dailySavings: 300, reductionPercent: 10, savingsGoal: 20_000)
        await harness.context.loadSimulationExplanation(input: scenarioB)

        guard case .unavailable = harness.context.simulatorExplanationState else {
            return XCTFail("A failed new scenario must not display scenario A's explanation")
        }
    }

    func testD6_SimulationCacheKeepsOnlyTheMostRecentScenarios() async throws {
        let harness = try makeHarness()
        for step in 0..<(AppContext.simulationCacheLimit + 4) {
            let input = SimulationInput(monthlyRunRate: 10_000, dailySavings: Double(step * 10), reductionPercent: 5, savingsGoal: 20_000)
            await harness.context.loadSimulationExplanation(input: input)
        }

        let records = try harness.modelContext.fetch(FetchDescriptor<AIResponseCacheRecord>())
        XCTAssertEqual(records.count, AppContext.simulationCacheLimit)
    }

    // MARK: - D7 savings is not spending

    func testD7_SavingsAreExcludedFromSpendingTotals() {
        let now = date(2024, 3, 15)
        let transactions = [
            TransactionRecord(amount: 100, merchantName: "Market", category: .groceries, date: date(2024, 3, 14)),
            TransactionRecord(amount: 500, merchantName: "Bank", category: .savings, date: date(2024, 3, 14))
        ]

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, now: now)

        XCTAssertEqual(summary.totalSpent, 100, accuracy: 0.001)
        XCTAssertEqual(summary.transactionCount, 1)
        XCTAssertEqual(summary.categoryBreakdown.map(\.category), [.groceries])
        XCTAssertEqual(summary.categoryBreakdown.first?.percentage ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(summary.averageTransactionValue, 100, accuracy: 0.001)
    }

    func testD7_RecurringSavingsTransfersAreNotRecurringSpend() {
        let now = date(2024, 3, 15)
        let summary = DefaultRecurringSummaryService(calendar: calendar).makeSummary(
            recurringExpenses: [
                RecurringExpenseRecord(merchantName: "Rent", amount: 1_000, category: .bills, expectedDay: 1),
                RecurringExpenseRecord(merchantName: "Auto-save", amount: 400, category: .savings, expectedDay: 5)
            ],
            transactions: [],
            now: now
        )

        XCTAssertEqual(summary.totalMonthlySpend, 1_000, accuracy: 0.001)
        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.largestItem?.merchantName, "Rent")
    }

    // MARK: - D8 simulator run-rate, no double counting, toggle semantics

    func testD8_RunRateScalesRecentSpendToAFullMonth() {
        let now = date(2024, 3, 3)
        // Only 3 days of history: the observed window is floored at 7 days, then scaled to 30.
        let early = [TransactionRecord(amount: 700, merchantName: "A", category: .dining, date: date(2024, 3, 2))]
        XCTAssertEqual(MonthlyRunRate.estimate(from: early, now: now, calendar: calendar), 700.0 / 7 * 30, accuracy: 0.001)

        // A full 30 days of history is taken as-is, and savings never count.
        let full = [
            TransactionRecord(amount: 1_000, merchantName: "A", category: .dining, date: date(2024, 2, 3)),
            TransactionRecord(amount: 2_000, merchantName: "B", category: .bills, date: date(2024, 3, 3)),
            TransactionRecord(amount: 9_999, merchantName: "Bank", category: .savings, date: date(2024, 3, 3)),
            TransactionRecord(amount: 5_000, merchantName: "Old", category: .travel, date: date(2023, 12, 1))
        ]
        XCTAssertEqual(MonthlyRunRate.estimate(from: full, now: now, calendar: calendar), 3_000, accuracy: 0.001)
        XCTAssertEqual(MonthlyRunRate.estimate(from: [], now: now, calendar: calendar), 0)
    }

    func testD8_PausedRecurringChargesAreNotDoubleCounted() {
        let projection = DefaultSimulationService().project(
            input: SimulationInput(
                monthlyRunRate: 10_000,
                recurringMonthlySpend: 2_000,
                dailySavings: 0,
                reductionPercent: 10,
                savingsGoal: 0,
                pausedRecurringMonthlySpend: 2_000
            )
        )

        // 10% of the 8,000 non-recurring spend + the 2,000 paused once = 2,800 (not 3,000).
        XCTAssertEqual(projection.monthlySavings, 2_800, accuracy: 0.001)
    }

    func testD8_PausedAmountNeverExceedsRecurringTotal() {
        let projection = DefaultSimulationService().project(
            input: SimulationInput(
                monthlyRunRate: 1_000,
                recurringMonthlySpend: 100,
                dailySavings: 0,
                reductionPercent: 0,
                savingsGoal: 0,
                pausedRecurringMonthlySpend: 5_000
            )
        )

        XCTAssertEqual(projection.monthlySavings, 100, accuracy: 0.001)
    }

    func testD8_ToggleOnMeansChargeKeepsRunning() {
        let netflix = makeRecurring("Netflix", amount: 700)
        let gym = makeRecurring("Gym", amount: 300)
        var selection = RecurringPauseSelection()

        XCTAssertTrue(selection.isIncluded(netflix.id))
        XCTAssertEqual(selection.pausedMonthlySpend(in: [netflix, gym]), 0)

        selection.setIncluded(false, for: netflix.id)
        XCTAssertFalse(selection.isIncluded(netflix.id))
        XCTAssertTrue(selection.isPaused(netflix.id))
        XCTAssertEqual(selection.pausedMonthlySpend(in: [netflix, gym]), 700, accuracy: 0.001)

        selection.setIncluded(true, for: netflix.id)
        XCTAssertEqual(selection.pausedMonthlySpend(in: [netflix, gym]), 0)
    }

    private func makeRecurring(_ name: String, amount: Double) -> RecurringTransaction {
        RecurringTransaction(
            id: UUID(),
            merchantName: name,
            normalizedMerchantName: name.lowercased(),
            category: .bills,
            monthlyAmount: amount,
            expectedDay: 1,
            expectedDate: .now,
            status: .upcoming,
            isActive: true,
            note: ""
        )
    }

    // MARK: - D9 locale-safe amounts, repository validation, no hard-wired currency

    func testD9_AmountParsingFollowsLocale() {
        XCTAssertEqual(AmountParser.parse("1,250.50", locale: Locale(identifier: "en_US")), 1_250.5)
        XCTAssertEqual(AmountParser.parse("12.50", locale: Locale(identifier: "en_US")), 12.5)
        XCTAssertEqual(AmountParser.parse("12,50", locale: Locale(identifier: "de_DE")), 12.5)
        XCTAssertEqual(AmountParser.parse("1.250,50", locale: Locale(identifier: "de_DE")), 1_250.5)
        XCTAssertEqual(AmountParser.parse("1 250,5", locale: Locale(identifier: "fr_FR")), 1_250.5)
        XCTAssertNil(AmountParser.parse("12abc", locale: Locale(identifier: "en_US")))
        XCTAssertNil(AmountParser.parse("", locale: Locale(identifier: "en_US")))
    }

    func testD9_DraftParsesWithItsLocale() {
        var draft = TransactionDraft()
        draft.locale = Locale(identifier: "de_DE")
        draft.amountText = "12,50"

        XCTAssertEqual(draft.amount, 12.5)
        draft.merchantName = "Cafe"
        XCTAssertNil(draft.validationError)
    }

    func testD9_RepositoriesRejectNonPositiveAmounts() throws {
        let harness = try makeHarness()
        let repository = SwiftDataTransactionRepository(modelContext: harness.modelContext)
        let recurringRepository = SwiftDataRecurringExpenseRepository(modelContext: harness.modelContext)

        for text in ["0", "-5"] {
            var draft = TransactionDraft()
            draft.locale = Locale(identifier: "en_US")
            draft.amountText = text
            draft.merchantName = "X"
            XCTAssertThrowsError(try repository.addTransaction(from: draft), text)

            var recurring = RecurringExpenseDraft()
            recurring.locale = Locale(identifier: "en_US")
            recurring.amountText = text
            recurring.merchantName = "X"
            XCTAssertThrowsError(try recurringRepository.addRecurringExpense(from: recurring), text)
        }
        XCTAssertTrue(try repository.fetchAllTransactions().isEmpty)

        // Updating an existing record to a non-positive amount is rejected too.
        try addTransaction(harness.context, amount: "10")
        let record = try XCTUnwrap(harness.context.transactions.first)
        var update = TransactionDraft(record: record)
        update.locale = Locale(identifier: "en_US")
        update.amountText = "0"
        XCTAssertThrowsError(try repository.updateTransaction(record, from: update))
        XCTAssertEqual(record.amount, 10, accuracy: 0.001)
    }

    func testD9_CurrencyUsesDeviceLocaleNotPesos() {
        XCTAssertEqual(CurrencyFormatter.currencyCode(for: Locale(identifier: "en_US")), "USD")
        XCTAssertEqual(CurrencyFormatter.currencyCode(for: Locale(identifier: "en_GB")), "GBP")
        XCTAssertEqual(CurrencyFormatter.string(from: 5, locale: Locale(identifier: "en_GB")), "£5.00")
    }

    func testD9_PromptsCarryTheDeviceCurrencyCode() {
        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: [], now: date(2024, 3, 15))

        XCTAssertTrue(PromptFactory.insightPrompt(for: .budgeting, summary: summary).contains("Currency: \(CurrencyFormatter.currencyCode)"))
        XCTAssertTrue(PromptFactory.bundlePrompt(summary: summary).contains("Currency: \(CurrencyFormatter.currencyCode)"))
    }

    // MARK: - Also-noted items

    func testBundleInstructionsBriefTheModelOnAllThreeCards() {
        let instructions = PromptFactory.bundleInstructions

        for kind in InsightKind.allCases {
            XCTAssertTrue(instructions.contains(kind.rawValue))
        }
        XCTAssertTrue(instructions.contains("## Key Takeaway"))
    }

    #if canImport(FoundationModels)
    func testCapabilityMessagesAreActionablePerReason() {
        let messages = [
            DefaultCapabilityService.message(for: .deviceNotEligible),
            DefaultCapabilityService.message(for: .appleIntelligenceNotEnabled),
            DefaultCapabilityService.message(for: .modelNotReady)
        ]

        XCTAssertEqual(Set(messages).count, 3)
    }
    #endif
}

/// Counts model calls and returns deterministic text.
private final class CountingAIService: AIInsightService, @unchecked Sendable {
    let providerIdentifier = "mock"
    private let lock = NSLock()
    private var _insightCalls = 0
    private var _simulationCalls = 0
    private var _failSimulation = false

    var insightCalls: Int { lock.withLock { _insightCalls } }
    var simulationCalls: Int { lock.withLock { _simulationCalls } }
    var failSimulation: Bool {
        get { lock.withLock { _failSimulation } }
        set { lock.withLock { _failSimulation = newValue } }
    }

    func generateInsights(
        from summary: MonthlySummary,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload {
        lock.withLock { _insightCalls += 1 }
        let cards = InsightKind.allCases.map { GeneratedInsightCard(kind: $0, markdown: "## Key Takeaway\n\n\($0.title)") }
        return GeneratedInsightPayload(cards: cards, providerIdentifier: providerIdentifier)
    }

    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)?
    ) async throws -> GeneratedSimulationExplanation {
        lock.withLock { _simulationCalls += 1 }
        if failSimulation { throw AIInsightError.unavailable("Model offline") }
        return GeneratedSimulationExplanation(
            markdown: "Explanation for \(projection.monthlySavings)",
            providerIdentifier: providerIdentifier
        )
    }
}
