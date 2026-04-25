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
            TransactionRecord(amount: 1000, category: .groceries, date: now),
            TransactionRecord(amount: 500, category: .transport, date: now),
            TransactionRecord(amount: 500, category: .groceries, date: now)
        ]

        let summary = DefaultSummaryService(calendar: calendar).makeMonthlySummary(from: transactions, now: now)

        XCTAssertEqual(summary.totalSpent, 2000, accuracy: 0.001)
        XCTAssertEqual(summary.transactionCount, 3)
        XCTAssertEqual(summary.topCategory, .groceries)
        XCTAssertEqual(summary.categoryBreakdown.first?.amount ?? 0, 1500, accuracy: 0.001)
    }

    func testSimulationServiceCalculatesGoalTimeline() {
        let projection = DefaultSimulationService().project(
            input: SimulationInput(
                currentMonthlySpending: 20_000,
                dailySavings: 100,
                reductionPercent: 20,
                savingsGoal: 50_000
            )
        )

        XCTAssertEqual(projection.monthlySavings, 7_000, accuracy: 0.001)
        XCTAssertEqual(projection.projectedSavingsSixMonths, 42_000, accuracy: 0.001)
        XCTAssertEqual(projection.monthsToGoal, 8)
    }

    func testCurrencyFormatterUsesPesoSymbol() {
        XCTAssertEqual(CurrencyFormatter.pesoString(from: 1234.5), "₱1,234.50")
    }

    @MainActor
    func testAppContextSaveFlowUpdatesSummary() throws {
        let schema = Schema([TransactionRecord.self, AIResponseCacheRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let repository = SwiftDataTransactionRepository(modelContext: modelContext)
        let summaryService = DefaultSummaryService()
        let context = AppContext(
            repository: repository,
            modelContext: modelContext,
            summaryService: summaryService,
            aiInsightService: UnsupportedAIInsightService(reason: "Unavailable"),
            simulationService: DefaultSimulationService(),
            capabilityService: DefaultCapabilityService()
        )

        var draft = TransactionDraft()
        draft.amountText = "250"
        draft.category = .dining
        draft.note = "Lunch"
        context.activeDraft = draft

        try context.saveDraft()

        XCTAssertEqual(context.transactions.count, 1)
        XCTAssertEqual(context.monthlySummary.totalSpent, 250, accuracy: 0.001)
        XCTAssertEqual(context.monthlySummary.topCategory, .dining)
    }

    func testMonthlyInsightFingerprintChangesWithMeaningfulSummaryChanges() {
        let now = Date(timeIntervalSince1970: 1_713_000_000)
        let baseSummary = MonthlySummary(
            monthStart: now,
            monthLabel: "April 2024",
            totalSpent: 2_000,
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
}
