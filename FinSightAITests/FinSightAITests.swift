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
        let schema = Schema([TransactionRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = SwiftDataTransactionRepository(modelContext: ModelContext(container))
        let summaryService = DefaultSummaryService()
        let context = AppContext(
            repository: repository,
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
}
