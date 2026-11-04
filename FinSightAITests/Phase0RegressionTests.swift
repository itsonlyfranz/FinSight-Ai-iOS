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

    // MARK: - D4 trend compares like with like, from real ledger numbers

    func testD4_TrendComparesTheSameDaysOfLastMonthEvenOnDayTwo() {
        // 2 March: the first two days of March against the first two days of February.
        let now = date(2024, 3, 2)
        let transactions = [
            TransactionRecord(amount: 900, merchantName: "A", category: .dining, date: date(2024, 3, 1)),
            TransactionRecord(amount: 100, merchantName: "B", category: .dining, date: date(2024, 2, 1)),
            TransactionRecord(amount: 5000, merchantName: "C", category: .dining, date: date(2024, 2, 20))  // outside the window
        ]

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, now: now)

        XCTAssertEqual(summary.spendingTrendDescription, "Spending is up 800% compared with the same days last month.")
    }

    func testD4_TrendDetectsLowerSpendingAndMissingBaseline() {
        let now = date(2024, 3, 20)
        let service = DefaultSummaryService(calendar: calendar)

        let lower = service.makeMonthlySummary(
            from: [
                TransactionRecord(amount: 100, merchantName: "A", category: .dining, date: date(2024, 3, 5)),
                TransactionRecord(amount: 900, merchantName: "B", category: .dining, date: date(2024, 2, 10))
            ],
            now: now
        )
        let noBaseline = service.makeMonthlySummary(
            from: [TransactionRecord(amount: 100, merchantName: "A", category: .dining, date: date(2024, 3, 19))],
            now: now
        )

        XCTAssertEqual(lower.spendingTrendDescription, "Spending is down 89% compared with the same days last month.")
        XCTAssertEqual(noBaseline.spendingTrendDescription, "No spending in the same days last month to compare against yet.")
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
        let scenarioA = narration(dailySavings: 100)
        let scenarioB = narration(dailySavings: 200)

        await harness.context.loadSimulationExplanation(context: scenarioA)
        await harness.context.loadSimulationExplanation(context: scenarioB)
        let records = try harness.modelContext.fetch(FetchDescriptor<AIResponseCacheRecord>())
        XCTAssertEqual(Set(records.map(\.cacheKey)).count, 2)

        // Back to A: shows A's own text from cache without another model call.
        await harness.context.loadSimulationExplanation(context: scenarioA)
        XCTAssertEqual(harness.ai.simulationCalls, 2)
        guard case .available(let content) = harness.context.simulatorExplanationState else {
            return XCTFail("Expected cached explanation")
        }
        XCTAssertEqual(content.value, "Explanation for \(scenarioA.facts)")
    }

    func testD6_NewScenarioDoesNotShowAnotherScenariosText() async throws {
        let harness = try makeHarness()
        await harness.context.loadSimulationExplanation(context: narration(dailySavings: 100))

        harness.ai.failSimulation = true
        await harness.context.loadSimulationExplanation(context: narration(dailySavings: 300))

        guard case .unavailable = harness.context.simulatorExplanationState else {
            return XCTFail("A failed new scenario must not display scenario A's explanation")
        }
    }

    func testD6_SimulationCacheKeepsOnlyTheMostRecentScenarios() async throws {
        let harness = try makeHarness()
        for step in 0..<(AppContext.simulationCacheLimit + 4) {
            await harness.context.loadSimulationExplanation(context: narration(dailySavings: Decimal(step * 10)))
        }

        let records = try harness.modelContext.fetch(FetchDescriptor<AIResponseCacheRecord>())
        XCTAssertEqual(records.count, AppContext.simulationCacheLimit)
    }

    /// The facts the model would be given for a scenario that only sets a daily saving.
    private func narration(dailySavings: Decimal) -> SimulationNarrationContext {
        let scenario = SimulationScenario(dailySavings: dailySavings)
        let result = ForwardSimulator.simulate(baseline: .empty, scenario: scenario, now: date(2024, 3, 1), calendar: calendar)
        return SimulationFacts.context(scenario: scenario, baseline: .empty, result: result)
    }

    private func runRate(_ transactions: [TransactionRecord], recurringSummary: RecurringSummary = .empty, now: Date) -> Double {
        RunRateBaseline.make(
            entries: transactions.map(LedgerEntry.init),
            recurring: RunRateBaseline.recurringCharges(from: recurringSummary),
            recurringTransactionIDs: recurringSummary.recurringTransactionIDs,
            now: now,
            calendar: calendar
        ).monthlyTotal.doubleValue
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
        XCTAssertEqual(runRate(early, now: now), 700.0 / 7 * 30, accuracy: 0.001)

        // A full 30 days of history is taken as-is, and savings never count.
        let full = [
            TransactionRecord(amount: 1_000, merchantName: "A", category: .dining, date: date(2024, 2, 3)),
            TransactionRecord(amount: 2_000, merchantName: "B", category: .bills, date: date(2024, 3, 3)),
            TransactionRecord(amount: 9_999, merchantName: "Bank", category: .savings, date: date(2024, 3, 3)),
            TransactionRecord(amount: 5_000, merchantName: "Old", category: .travel, date: date(2023, 12, 1))
        ]
        XCTAssertEqual(runRate(full, now: now), 3_000, accuracy: 0.001)
        XCTAssertEqual(runRate([], now: now), 0)
    }

    func testD8_RunRateAddsRecurringChargesOnceInsteadOfScalingThem() {
        let now = date(2024, 3, 3)
        let rent = RecurringExpenseRecord(merchantName: "Rent", amount: 10_000, category: .bills, expectedDay: 3)
        let rentPayment = TransactionRecord(amount: 10_000, merchantName: "Rent", category: .bills, date: date(2024, 3, 3))
        let coffee = TransactionRecord(amount: 70, merchantName: "Cafe", category: .dining, date: date(2024, 3, 3))
        let recurring = DefaultRecurringSummaryService(calendar: calendar).makeSummary(
            recurringExpenses: [rent],
            transactions: [rentPayment, coffee],
            now: now
        )

        let logged = runRate([rentPayment, coffee], recurringSummary: recurring, now: now)
        XCTAssertEqual(logged, 70.0 / 7 * 30 + 10_000, accuracy: 0.001)

        let notYetLogged = runRate([coffee], recurringSummary: recurring, now: now)
        XCTAssertEqual(notYetLogged, 70.0 / 7 * 30 + 10_000, accuracy: 0.001)

        // The rent is counted once and is not everyday spending, so a 10% dining cut frees 10% of the 300 coffee run-rate.
        let baseline = RunRateBaseline.make(
            entries: [rentPayment, coffee].map(LedgerEntry.init),
            recurring: RunRateBaseline.recurringCharges(from: recurring),
            recurringTransactionIDs: recurring.recurringTransactionIDs,
            now: now,
            calendar: calendar
        )
        var scenario = SimulationScenario()
        scenario.setCut(10, for: .dining)
        let result = ForwardSimulator.simulate(baseline: baseline, scenario: scenario, now: now, calendar: calendar)
        XCTAssertEqual(result.monthlySavings.doubleValue, 30, accuracy: 0.001)
    }

    func testD8_PausedRecurringChargesAreNotDoubleCounted() {
        let rent = RecurringCharge(id: UUID(), name: "Rent", category: .bills, monthlyAmount: 2_000)
        let baseline = RunRateBaseline(
            lines: [
                RunRateBaseline.Line(category: .dining, discretionary: 8_000, recurring: 0),
                RunRateBaseline.Line(category: .bills, discretionary: 0, recurring: 2_000)
            ],
            excludedOneOffs: [],
            recurringCharges: [rent],
            categoryVolatility: [:]
        )
        var scenario = SimulationScenario()
        scenario.setCut(10, for: .dining)
        scenario.setCut(10, for: .bills)
        scenario.setRecurring(rent.id, included: false)

        let result = ForwardSimulator.simulate(baseline: baseline, scenario: scenario, now: date(2024, 3, 1), calendar: calendar)

        // 10% of the 8,000 everyday spending + the 2,000 paused once = 2,800 (not 3,000, and the
        // bills cut finds no everyday spending to cut).
        XCTAssertEqual(result.monthlySavings, 2_800)
    }

    func testD8_OnlyExistingChargesCanBePaused() {
        let rent = RecurringCharge(id: UUID(), name: "Rent", category: .bills, monthlyAmount: 100)
        let baseline = RunRateBaseline(lines: [], excludedOneOffs: [], recurringCharges: [rent], categoryVolatility: [:])
        var scenario = SimulationScenario()
        scenario.setRecurring(UUID(), included: false)
        XCTAssertEqual(ForwardSimulator.simulate(baseline: baseline, scenario: scenario, now: date(2024, 3, 1), calendar: calendar).monthlySavings, 0)

        scenario.setRecurring(rent.id, included: false)
        XCTAssertEqual(ForwardSimulator.simulate(baseline: baseline, scenario: scenario, now: date(2024, 3, 1), calendar: calendar).monthlySavings, 100)
    }

    func testD8_ToggleOnMeansChargeKeepsRunning() {
        let netflix = UUID()
        var scenario = SimulationScenario()

        XCTAssertFalse(scenario.pausedRecurringIDs.contains(netflix))

        scenario.setRecurring(netflix, included: false)
        XCTAssertTrue(scenario.pausedRecurringIDs.contains(netflix))

        scenario.setRecurring(netflix, included: true)
        XCTAssertTrue(scenario.pausedRecurringIDs.isEmpty)
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
        let context = NarrationContext(summary: summary, insights: [], ledger: .empty)

        XCTAssertTrue(context.prompt(maxTokens: 2_000).text.contains("Currency: \(CurrencyFormatter.currencyCode)"))
    }

    // MARK: - Also-noted items

    func testNarrationInstructionsBriefTheModelOnAllThreeCards() {
        let instructions = PromptFactory.narrationInstructions

        for kind in InsightKind.allCases {
            XCTAssertTrue(instructions.contains(kind.rawValue))
        }
        for tool in ["categoryTotals", "transactions", "budgetStatus"] {
            XCTAssertTrue(instructions.contains(tool))
        }
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
        from context: NarrationContext,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload {
        lock.withLock { _insightCalls += 1 }
        let cards = InsightKind.allCases.map { GeneratedInsightCard(kind: $0, markdown: "## Key Takeaway\n\n\($0.title)") }
        return GeneratedInsightPayload(cards: cards, providerIdentifier: providerIdentifier)
    }

    func explainSimulation(
        context: SimulationNarrationContext,
        onUpdate: (@Sendable (String) async -> Void)?
    ) async throws -> GeneratedSimulationExplanation {
        lock.withLock { _simulationCalls += 1 }
        if failSimulation { throw AIInsightError.unavailable("Model offline") }
        return GeneratedSimulationExplanation(
            markdown: "Explanation for \(context.facts)",
            providerIdentifier: providerIdentifier
        )
    }
}
