import SwiftData
import XCTest
@testable import FinSightAI

final class FinSightAITests: XCTestCase {
    func testTransactionDraftRejectsInvalidAmount() {
        var draft = TransactionDraft()
        draft.amountText = "0"

        XCTAssertEqual(draft.validationError, "Amount must be greater than zero.")
    }

    func testSummaryServiceBuildsCategoryBreakdown() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let transactions = [
            TransactionRecord(amount: 1000, merchantName: "Landers", category: .groceries, date: now),
            TransactionRecord(amount: 500, merchantName: "Grab", category: .transport, date: now),
            TransactionRecord(amount: 500, merchantName: "Landers", category: .groceries, date: now)
        ]

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, now: now)

        XCTAssertEqual(summary.totalSpent, 2000, accuracy: 0.001)
        XCTAssertEqual(summary.transactionCount, 3)
        XCTAssertEqual(summary.topCategory, .groceries)
        XCTAssertEqual(summary.categoryBreakdown.first?.amount ?? 0, 1500, accuracy: 0.001)
    }

    func testRecurringSummaryUsesManualDefinitions() {
        let calendar = Calendar(identifier: .gregorian)
        let now = makeDate(year: 2024, month: 4, day: 10, calendar: calendar)
        let recurringExpenses = [
            RecurringExpenseRecord(
                merchantName: "Netflix",
                amount: 720,
                category: .entertainment,
                expectedDay: 15
            )
        ]

        let summary = DefaultRecurringSummaryService(calendar: calendar).makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: [],
            now: now
        )

        XCTAssertEqual(summary.itemCount, 1)
        XCTAssertEqual(summary.totalMonthlySpend, 720, accuracy: 0.001)
        XCTAssertEqual(summary.items.first?.merchantName, "Netflix")
        XCTAssertEqual(summary.items.first?.status, .upcoming)
    }

    func testRecurringSummaryIgnoresInactiveDefinitions() {
        let calendar = Calendar(identifier: .gregorian)
        let now = makeDate(year: 2024, month: 4, day: 10, calendar: calendar)
        let recurringExpenses = [
            RecurringExpenseRecord(
                merchantName: "Netflix",
                amount: 720,
                category: .entertainment,
                expectedDay: 15,
                isActive: false
            )
        ]

        let summary = DefaultRecurringSummaryService(calendar: calendar).makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: [],
            now: now
        )

        XCTAssertTrue(summary.items.isEmpty)
    }

    func testRecurringSummaryMatchesTransactionsForClassification() {
        let calendar = Calendar(identifier: .gregorian)
        let now = makeDate(year: 2024, month: 4, day: 10, calendar: calendar)
        let netflix = TransactionRecord(amount: 720, merchantName: "Netflix, Inc.", category: .entertainment, date: now)
        let transactions = [
            netflix,
            TransactionRecord(amount: 100, merchantName: "Coffee Shop", category: .dining, date: now),
            TransactionRecord(amount: 1_500, merchantName: "Netflix", category: .entertainment, date: now)
        ]
        let recurringExpenses = [
            RecurringExpenseRecord(
                merchantName: "NETFLIX INC",
                amount: 720,
                category: .entertainment,
                expectedDay: 15
            )
        ]

        let summary = DefaultRecurringSummaryService(calendar: calendar).makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            now: now
        )

        XCTAssertEqual(summary.recurringTransactionIDs, [netflix.id])
    }

    func testRecurringSummaryUsesScheduleOnlyStatus() {
        let calendar = Calendar(identifier: .gregorian)
        let recurringExpenses = [
            RecurringExpenseRecord(merchantName: "Rent", amount: 15_000, category: .bills, expectedDay: 10)
        ]
        let service = DefaultRecurringSummaryService(calendar: calendar, gracePeriodDays: 3)

        let upcoming = service.makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: [],
            now: makeDate(year: 2024, month: 4, day: 9, calendar: calendar)
        )
        let due = service.makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: [],
            now: makeDate(year: 2024, month: 4, day: 13, calendar: calendar)
        )
        let missed = service.makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: [],
            now: makeDate(year: 2024, month: 4, day: 14, calendar: calendar)
        )

        XCTAssertEqual(upcoming.items.first?.status, .upcoming)
        XCTAssertEqual(due.items.first?.status, .due)
        XCTAssertEqual(missed.items.first?.status, .missed)
    }

    func testSummaryServiceSeparatesRecurringFromOneOffSpend() {
        let calendar = Calendar(identifier: .gregorian)
        let now = makeDate(year: 2024, month: 3, day: 15, calendar: calendar)
        let transactions = [
            TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: makeDate(year: 2024, month: 3, day: 5, calendar: calendar)),
            TransactionRecord(amount: 100, merchantName: "Coffee Shop", category: .dining, date: makeDate(year: 2024, month: 3, day: 6, calendar: calendar))
        ]
        let recurringSummary = DefaultRecurringSummaryService(calendar: calendar).makeSummary(
            recurringExpenses: [
                RecurringExpenseRecord(
                    merchantName: "Netflix",
                    amount: 720,
                    category: .entertainment,
                    expectedDay: 5
                )
            ],
            transactions: transactions,
            now: now
        )

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(
            from: transactions,
            recurringSummary: recurringSummary,
            now: now
        )

        XCTAssertEqual(summary.recurringMonthlySpend, 720, accuracy: 0.001)
        XCTAssertEqual(summary.recurringTransactionCount, 1)
        XCTAssertEqual(summary.oneOffSpent, 100, accuracy: 0.001)
    }

    func testRecurringDraftPrefillsFromTransaction() {
        let calendar = Calendar(identifier: .gregorian)
        let transaction = TransactionRecord(
            amount: 1_250,
            merchantName: "Spotify",
            category: .entertainment,
            date: makeDate(year: 2024, month: 4, day: 18, calendar: calendar),
            note: "Family plan"
        )

        let draft = RecurringExpenseDraft(transaction: transaction, calendar: calendar)

        XCTAssertEqual(draft.merchantName, "Spotify")
        XCTAssertEqual(draft.amount, 1_250)
        XCTAssertEqual(draft.category, .entertainment)
        XCTAssertEqual(draft.expectedDay, 18)
        XCTAssertEqual(draft.note, "Family plan")
    }

    func testSimulationServiceCalculatesGoalTimeline() {
        let projection = DefaultSimulationService().project(
            input: SimulationInput(
                currentMonthlySpending: 20_000,
                dailySavings: 100,
                reductionPercent: 20,
                savingsGoal: 50_000,
                disabledRecurringMonthlySpend: 500
            )
        )

        XCTAssertEqual(projection.monthlySavings, 7_500, accuracy: 0.001)
        XCTAssertEqual(projection.projectedSavingsSixMonths, 45_000, accuracy: 0.001)
        XCTAssertEqual(projection.monthsToGoal, 7)
    }

    func testCurrencyFormatterUsesPesoSymbol() {
        XCTAssertEqual(CurrencyFormatter.pesoString(from: 1234.5), "₱1,234.50")
    }

    @MainActor
    func testRecurringExpenseRepositoryCreatesUpdatesAndDeletesRecords() throws {
        let schema = Schema([RecurringExpenseRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = SwiftDataRecurringExpenseRepository(modelContext: ModelContext(container))

        var draft = RecurringExpenseDraft()
        draft.merchantName = "Netflix"
        draft.amountText = "720"
        draft.category = .entertainment
        draft.expectedDay = 15
        draft.note = "Family plan"

        try repository.addRecurringExpense(from: draft)
        var records = try repository.fetchAllRecurringExpenses()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.merchantName, "Netflix")
        XCTAssertEqual(records.first?.amount ?? 0, 720, accuracy: 0.001)

        let record = try XCTUnwrap(records.first)
        draft.amountText = "750"
        draft.isActive = false
        try repository.updateRecurringExpense(record, from: draft)
        records = try repository.fetchAllRecurringExpenses()

        XCTAssertEqual(records.first?.amount ?? 0, 750, accuracy: 0.001)
        XCTAssertEqual(records.first?.isActive, false)

        try repository.deleteRecurringExpense(record)
        XCTAssertTrue(try repository.fetchAllRecurringExpenses().isEmpty)
    }

    @MainActor
    func testAppContextSaveFlowUpdatesSummary() throws {
        let schema = Schema([TransactionRecord.self, RecurringExpenseRecord.self, AIResponseCacheRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let repository = SwiftDataTransactionRepository(modelContext: modelContext)
        let recurringRepository = SwiftDataRecurringExpenseRepository(modelContext: modelContext)
        let summaryService = DefaultSummaryService()
        let context = AppContext(
            repository: repository,
            recurringExpenseRepository: recurringRepository,
            modelContext: modelContext,
            summaryService: summaryService,
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: UnsupportedAIInsightService(reason: "Unavailable"),
            simulationService: DefaultSimulationService(),
            capabilityService: DefaultCapabilityService()
        )

        var draft = TransactionDraft()
        draft.amountText = "250"
        draft.merchantName = "Cafe Mary Grace"
        draft.category = .dining
        draft.note = "Lunch"
        context.activeDraft = draft

        try context.saveDraft()

        XCTAssertEqual(context.transactions.count, 1)
        XCTAssertEqual(context.transactions.first?.merchantName, "Cafe Mary Grace")
        XCTAssertEqual(context.monthlySummary.totalSpent, 250, accuracy: 0.001)
        XCTAssertEqual(context.monthlySummary.topCategory, .dining)
    }

    @MainActor
    func testAppContextRecurringSaveFlowUpdatesSummary() throws {
        let schema = Schema([TransactionRecord.self, RecurringExpenseRecord.self, AIResponseCacheRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: UnsupportedAIInsightService(reason: "Unavailable"),
            simulationService: DefaultSimulationService(),
            capabilityService: DefaultCapabilityService()
        )

        var draft = RecurringExpenseDraft()
        draft.merchantName = "Netflix"
        draft.amountText = "720"
        draft.category = .entertainment
        draft.expectedDay = 15
        context.activeRecurringDraft = draft

        try context.saveRecurringDraft()

        XCTAssertEqual(context.recurringExpenses.count, 1)
        XCTAssertEqual(context.recurringSummary.totalMonthlySpend, 720, accuracy: 0.001)
        XCTAssertEqual(context.monthlySummary.recurringTransactionCount, 1)
    }

    func testMonthlyInsightFingerprintChangesWithMeaningfulSummaryChanges() {
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let baseSummary = MonthlySummary(
            monthStart: now,
            monthLabel: "April 2024",
            totalSpent: 2_000,
            recurringMonthlySpend: 500,
            recurringTransactionCount: 1,
            oneOffSpent: 1_500,
            largestRecurringMerchant: "Netflix",
            transactionCount: 3,
            categoryBreakdown: [
                CategorySpend(category: .groceries, amount: 1_500, percentage: 0.75),
                CategorySpend(category: .transport, amount: 500, percentage: 0.25)
            ],
            recentTransactions: [],
            averageTransactionValue: 666.67,
            topCategory: .groceries,
            topCategoryShare: 0.75,
            spendingTrendDescription: "Spending is up 10% month over month."
        )
        let sameSummary = baseSummary
        let changedSummary = MonthlySummary(
            monthStart: now,
            monthLabel: "April 2024",
            totalSpent: 2_500,
            recurringMonthlySpend: 500,
            recurringTransactionCount: 1,
            oneOffSpent: 2_000,
            largestRecurringMerchant: "Netflix",
            transactionCount: 3,
            categoryBreakdown: baseSummary.categoryBreakdown,
            recentTransactions: [],
            averageTransactionValue: 833.33,
            topCategory: .groceries,
            topCategoryShare: 0.75,
            spendingTrendDescription: baseSummary.spendingTrendDescription
        )

        XCTAssertEqual(
            AIFingerprint.monthlyInsights(summary: baseSummary),
            AIFingerprint.monthlyInsights(summary: sameSummary)
        )
        XCTAssertNotEqual(
            AIFingerprint.monthlyInsights(summary: baseSummary),
            AIFingerprint.monthlyInsights(summary: changedSummary)
        )
    }

    func testSimulationFingerprintIsStableForSameInputs() {
        let input = SimulationInput(
            currentMonthlySpending: 20_000,
            dailySavings: 100,
            reductionPercent: 20,
            savingsGoal: 50_000
        )
        let projection = DefaultSimulationService().project(input: input)

        XCTAssertEqual(
            AIFingerprint.simulation(input: input, projection: projection),
            AIFingerprint.simulation(input: input, projection: projection)
        )
    }

    func testAutomaticRefreshPolicyUsesFingerprintAndDailyCap() {
        let record = AIResponseCacheRecord(
            cacheKey: "monthly-insights:2024-04",
            feature: .monthlyInsights,
            sourceFingerprint: "fingerprint-a",
            payload: "[]",
            generatedAt: .now,
            lastAutoRefreshDayKey: "2024-04-01",
            providerIdentifier: "mock"
        )

        XCTAssertFalse(
            AIRefreshPolicy.needsAutomaticRefresh(
                record: record,
                fingerprint: "fingerprint-a",
                currentDayKey: "2024-04-01"
            )
        )
        XCTAssertTrue(
            AIRefreshPolicy.needsAutomaticRefresh(
                record: record,
                fingerprint: "fingerprint-b",
                currentDayKey: "2024-04-01"
            )
        )
        XCTAssertTrue(
            AIRefreshPolicy.needsAutomaticRefresh(
                record: record,
                fingerprint: "fingerprint-a",
                currentDayKey: "2024-04-02"
            )
        )
    }

    func testMarkdownCodecRoundTripsInsightCards() throws {
        let cards = [
            GeneratedInsightCard(
                kind: .budgeting,
                markdown: "## Key Takeaway\n\n**Cut** dining by 10%.\n- Reduce takeout\n- Cook twice more"
            )
        ]

        let payload = try AICacheCodec.encodeInsights(cards)
        let decoded = try AICacheCodec.decodeInsights(from: payload)

        XCTAssertEqual(decoded, cards)
    }

    func testInsightPromptInstructionsStayStructuredForMarkdownRendering() {
        for kind in InsightKind.allCases {
            let instructions = PromptFactory.instructions(for: kind)

            XCTAssertTrue(instructions.contains("## Key Takeaway"))
            XCTAssertTrue(instructions.contains("## Why It Matters"))
            XCTAssertTrue(instructions.contains("## Next Step"))
            XCTAssertTrue(instructions.localizedCaseInsensitiveContains("bullet"))
        }
    }

    func testSimulationInstructionsStayStructuredForMarkdownRendering() {
        let instructions = PromptFactory.simulationInstructions

        XCTAssertTrue(instructions.contains("## Scenario Summary"))
        XCTAssertTrue(instructions.contains("## Tradeoff"))
        XCTAssertTrue(instructions.contains("## Recommended Next Step"))
        XCTAssertTrue(instructions.localizedCaseInsensitiveContains("bullet"))
    }

    private func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }
}
