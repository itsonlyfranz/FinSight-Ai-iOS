import SwiftData
import XCTest
@testable import FinSightAI

/// Runs the real on-device model. Skipped, with the reason, wherever Apple Intelligence isn't available
/// (most CI runners and simulators); where it is, these exercise the actual Foundation Models paths.
@MainActor
final class OnDeviceModelSmokeTests: XCTestCase {
    private let capability = DefaultCapabilityService()

    override func setUpWithError() throws {
        if case .unavailable(let reason) = capability.aiAvailability {
            print("[smoke] on-device model unavailable: \(reason)")
            throw XCTSkip("On-device model unavailable: \(reason.message)")
        }
        print("[smoke] on-device model AVAILABLE")
    }

    func testNarrationStreamsStructuredCardsFromTheRealModel() async throws {
        let now = InsightFixtures.date(2024, 2, 15)
        let entries = [
            InsightFixtures.spend(200, .groceries, merchant: "Lidl", on: InsightFixtures.date(2024, 1, 5)),
            InsightFixtures.spend(300, .dining, merchant: "Bistro", on: InsightFixtures.date(2024, 1, 9)),
            InsightFixtures.spend(150, .groceries, merchant: "Lidl", on: InsightFixtures.date(2024, 2, 5)),
            InsightFixtures.spend(180, .dining, merchant: "Bistro", on: InsightFixtures.date(2024, 2, 9)),
            InsightFixtures.spend(100, .groceries, merchant: "Lidl", on: InsightFixtures.date(2023, 12, 5)),
            InsightFixtures.spend(60, .groceries, merchant: "Lidl", on: InsightFixtures.date(2023, 11, 5))
        ]
        let budgets = [BudgetLimit(category: .dining, limit: 100)]
        let ledger = LedgerSnapshot(now: now, calendar: InsightFixtures.utc, entries: entries, budgets: budgets)
        let summary = DefaultSummaryService(calendar: InsightFixtures.utc).makeMonthlySummary(from: [], now: now)
        let insights = InsightFixtures.run(now: now, entries: entries, budgets: budgets)
        let context = NarrationContext(summary: summary, insights: insights, ledger: ledger)

        let service = AppleFoundationModelsInsightService()
        service.prewarm()
        let updates = UpdateCounter()
        let payload = try await service.generateInsights(from: context) { _ in await updates.increment() }

        print("[smoke] narration partial updates: \(await updates.count)")
        for card in payload.cards { print("[smoke] \(card.kind.rawValue):\n\(card.markdown)\n") }
        XCTAssertEqual(payload.cards.map(\.kind), InsightKind.allCases)
        XCTAssertTrue(payload.cards.allSatisfy { $0.markdown.contains("## Key Takeaway") && $0.markdown.contains("## Next Step") })
        let streamed = await updates.count
        XCTAssertGreaterThan(streamed, 1, "partials should stream before the final result")
    }

    /// Regression: with the app's own sample data, tool-call turns used to grow the transcript past the
    /// 4,096-token context after ~13 minutes, and the raw token error reached the Insights screen.
    func testNarrationFinishesOverTheBuiltInSampleData() async throws {
        let container = try ModelContainer(for: AppStoreSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let service = AppleFoundationModelsInsightService()
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: service,
            simulationService: DefaultSimulationService(),
            capabilityService: capability
        )
        try context.loadSampleData()
        let narration = NarrationContext(summary: context.monthlySummary, insights: context.engineInsights, ledger: context.narrationLedger)

        let start = ContinuousClock.now
        do {
            let payload = try await service.generateInsights(from: narration, onUpdate: nil)
            print("[smoke] sample-data narration in \(ContinuousClock.now - start)")
            XCTAssertEqual(payload.cards.map(\.kind), InsightKind.allCases)
        } catch let error as AIInsightError {
            // Hiding ungrounded figures is an accepted outcome; anything else is a failure to narrate.
            print("[smoke] sample-data narration error after \(ContinuousClock.now - start): \(error)")
            XCTAssertEqual(error, .ungroundedFigures)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(300), "narration must not keep the spinner up for minutes")
    }

    func testRealModelCategorizesAnUnknownMerchant() async throws {
        let assistant = FoundationModelsTransactionAssistant()
        let suggestion = await assistant.suggestCategory(merchant: "Quick Fix Bike Repair", note: "new brake pads")
        print("[smoke] categorize 'Quick Fix Bike Repair': \(String(describing: suggestion))")
        let result = try XCTUnwrap(suggestion)
        XCTAssertEqual(result.source, .model)
    }

    func testRealModelReadsAQuickAddSentenceButNumbersStayInCode() async throws {
        let assistant = FoundationModelsTransactionAssistant()
        let now = InsightFixtures.date(2024, 3, 13)
        let result = await assistant.parseQuickAdd("paid dentist 80 last friday", now: now, calendar: InsightFixtures.utc, locale: Locale(identifier: "en_US"))
        print("[smoke] quick-add: \(result)")
        XCTAssertEqual(result.amount, 80)
        XCTAssertEqual(InsightFixtures.utc.startOfDay(for: result.date), InsightFixtures.utc.startOfDay(for: InsightFixtures.date(2024, 3, 8)))
        XCTAssertTrue(result.isComplete)
    }
}

private actor UpdateCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
