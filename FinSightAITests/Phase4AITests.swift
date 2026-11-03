import SwiftData
import XCTest
@testable import FinSightAI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Phase 4: availability handling, grounding, tools' data, auto-categorization and quick-add.
/// Everything here runs against deterministic stand-ins; `OnDeviceModelSmokeTests` covers the real model.
@MainActor
final class Phase4AITests: XCTestCase {
    private let utc = InsightFixtures.utc
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { InsightFixtures.date(y, m, d) }
    private func dec(_ text: String) -> Decimal { InsightFixtures.dec(text) }

    // MARK: - Availability fallback

    func testEveryUnavailableReasonHasItsOwnCopyAndActionability() {
        let reasons: [AIUnavailableReason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unsupportedSDK, .unknown]

        XCTAssertEqual(Set(reasons.map(\.title)).count, reasons.count)
        XCTAssertEqual(Set(reasons.map(\.message)).count, reasons.count)
        XCTAssertFalse(AIUnavailableReason.deviceNotEligible.isRecoverable)
        XCTAssertNil(AIUnavailableReason.deviceNotEligible.actionHint)
        XCTAssertTrue(AIUnavailableReason.appleIntelligenceNotEnabled.isRecoverable)
        XCTAssertTrue(AIUnavailableReason.appleIntelligenceNotEnabled.actionHint?.contains("Settings") == true)
        XCTAssertTrue(AIUnavailableReason.modelNotReady.isRecoverable)
    }

    func testAvailabilityExposesItsReason() {
        XCTAssertTrue(AIAvailability.available.isAvailable)
        XCTAssertNil(AIAvailability.available.reason)
        XCTAssertEqual(AIAvailability.unavailable(.modelNotReady).reason, .modelNotReady)
        XCTAssertEqual(AIAvailability.unavailable(.modelNotReady).message, AIUnavailableReason.modelNotReady.message)
    }

    #if canImport(FoundationModels)
    func testSystemReasonsMapOneToOne() {
        XCTAssertEqual(DefaultCapabilityService.reason(for: .deviceNotEligible), .deviceNotEligible)
        XCTAssertEqual(DefaultCapabilityService.reason(for: .appleIntelligenceNotEnabled), .appleIntelligenceNotEnabled)
        XCTAssertEqual(DefaultCapabilityService.reason(for: .modelNotReady), .modelNotReady)
    }

    func testAppleServiceReportsTheSpecificReasonInsteadOfCallingTheModel() async {
        for reason in [AIUnavailableReason.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady] {
            let service = AppleFoundationModelsInsightService(capabilityService: StaticCapabilityService(aiAvailability: .unavailable(reason)))
            do {
                _ = try await service.generateInsights(from: makeNarrationContext(), onUpdate: nil)
                XCTFail("expected \(reason) to throw")
            } catch let error as AIInsightError {
                XCTAssertEqual(error, .modelUnavailable(reason))
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testPrewarmDoesNothingWhenTheModelIsUnavailable() {
        // Must not crash or touch the model on an ineligible device.
        AppleFoundationModelsInsightService(capabilityService: StaticCapabilityService(aiAvailability: .unavailable(.deviceNotEligible))).prewarm()
        FoundationModelsTransactionAssistant(capabilityService: StaticCapabilityService(aiAvailability: .unavailable(.deviceNotEligible))).prewarm()
    }
    #endif

    func testUnavailableModelShowsItsReasonAndKeepsTheLedgerInsights() async throws {
        let harness = try makeHarness(ai: ScriptedAIService(behavior: .unavailable(.appleIntelligenceNotEnabled)))
        try seedLedger(harness.context)

        await harness.context.loadInsights()

        XCTAssertEqual(harness.context.insightState, .modelUnavailable(.appleIntelligenceNotEnabled))
        XCTAssertFalse(harness.context.allEngineInsights.isEmpty, "the deterministic insights don't depend on the model")
    }

    func testUnavailableModelFallsBackToTheCachedNarration() async throws {
        let ai = ScriptedAIService(behavior: .succeed)
        let harness = try makeHarness(ai: ai)
        try seedLedger(harness.context)
        await harness.context.loadInsights()
        guard case .available(let first) = harness.context.insightState else { return XCTFail("expected cards") }

        ai.behavior = .unavailable(.modelNotReady)
        await harness.context.loadInsights(forceRefresh: true)

        guard case .available(let content) = harness.context.insightState else { return XCTFail("cache should stay visible") }
        XCTAssertEqual(content.value.map(\.markdown), first.value.map(\.markdown))
        XCTAssertEqual(content.statusMessage, AIUnavailableReason.modelNotReady.message)
    }

    func testGenericFailureStillSurfacesAsUnavailableText() async throws {
        let harness = try makeHarness(ai: ScriptedAIService(behavior: .fail("boom")))
        try seedLedger(harness.context)

        await harness.context.loadInsights()

        XCTAssertEqual(harness.context.insightState, .unavailable("boom"))
    }

    // MARK: - Grounding and token budget

    func testPromptCarriesTypedInsightsAndThreeMonthsOfHistory() {
        let context = makeNarrationContext()
        let prompt = context.prompt(maxTokens: 4_000)

        XCTAssertEqual(prompt.historyMonths, NarrationContext.historyMonths)
        XCTAssertEqual(prompt.omittedInsightCount, 0)
        XCTAssertEqual(prompt.includedInsightIDs, context.insights.map(\.id))
        for insight in context.insights {
            XCTAssertTrue(prompt.text.contains(insight.title), "missing \(insight.title)")
        }
        XCTAssertTrue(prompt.text.contains("Previous months:"))
        // January, December and November sit before February 2024.
        for month in ["January 2024", "December 2023", "November 2023"] {
            XCTAssertTrue(prompt.text.contains(month), "missing \(month)")
        }
    }

    func testPromptTrimsToTheTokenBudgetKeepingTheMostImportantInsight() {
        let context = makeNarrationContext()
        let roomy = context.prompt(maxTokens: 4_000)
        let tight = context.prompt(maxTokens: roomy.estimatedTokens / 2)

        XCTAssertLessThanOrEqual(tight.estimatedTokens, roomy.estimatedTokens / 2)
        XCTAssertLessThan(tight.includedInsightIDs.count + tight.historyMonths, roomy.includedInsightIDs.count + roomy.historyMonths)
        if let kept = tight.includedInsightIDs.first {
            XCTAssertEqual(kept, context.insights.first?.id, "the highest-ranked insight is kept first")
        }
        XCTAssertEqual(tight.omittedInsightCount, context.insights.count - tight.includedInsightIDs.count)
    }

    func testPromptNeverReturnsNothingEvenWhenTheBudgetIsTiny() {
        let prompt = makeNarrationContext().prompt(maxTokens: 10)

        XCTAssertFalse(prompt.text.isEmpty)
        XCTAssertTrue(prompt.includedInsightIDs.isEmpty)
    }

    func testTokenBudgetLeavesRoomForTheResponse() {
        XCTAssertEqual(TokenBudget.promptBudget(contextSize: 4_096), 4_096 - TokenBudget.responseReserve - TokenBudget.overheadReserve)
        XCTAssertEqual(TokenBudget.promptBudget(contextSize: 100), TokenBudget.minimumPromptTokens)
        XCTAssertGreaterThanOrEqual(TokenBudget.estimate("twelve chars"), 4)
    }

    func testFingerprintChangesWhenInsightsOrHistoryChange() {
        let context = makeNarrationContext()
        let base = AIFingerprint.monthlyInsights(summary: context.summary, insights: context.insights, historyTotals: context.ledger.historyTotals)

        XCTAssertEqual(base, AIFingerprint.monthlyInsights(summary: context.summary, insights: context.insights, historyTotals: context.ledger.historyTotals))
        XCTAssertNotEqual(base, AIFingerprint.monthlyInsights(summary: context.summary, insights: Array(context.insights.dropFirst()), historyTotals: context.ledger.historyTotals))
        XCTAssertNotEqual(base, AIFingerprint.monthlyInsights(summary: context.summary, insights: context.insights, historyTotals: [1, 2, 3, 4]))
    }

    func testUnchangedDataDoesNotCallTheModelAgainToday() async throws {
        let ai = ScriptedAIService(behavior: .succeed)
        let harness = try makeHarness(ai: ai)
        try seedLedger(harness.context)

        await harness.context.loadInsights()
        await harness.context.loadInsights()

        XCTAssertEqual(ai.calls, 1, "the fingerprint cache still short-circuits repeat loads")
    }

    func testEditingDataRegeneratesTheNarration() async throws {
        let ai = ScriptedAIService(behavior: .succeed)
        let harness = try makeHarness(ai: ai)
        try seedLedger(harness.context)
        await harness.context.loadInsights()

        var draft = TransactionDraft()
        draft.locale = Locale(identifier: "en_US")
        draft.amountText = "75"
        draft.merchantName = "Bookshop"
        draft.category = .shopping
        harness.context.activeDraft = draft
        try harness.context.saveDraft()
        await harness.context.loadInsights()

        XCTAssertEqual(ai.calls, 2)
    }

    func testTheNarrationContextIsBuiltFromTheLiveLedger() async throws {
        let ai = ScriptedAIService(behavior: .succeed)
        let harness = try makeHarness(ai: ai)
        try seedLedger(harness.context)

        await harness.context.loadInsights()

        let context = try XCTUnwrap(ai.lastContext)
        XCTAssertEqual(context.insights.map(\.id), harness.context.engineInsights.map(\.id))
        XCTAssertFalse(context.ledger.entries.isEmpty)
    }

    // MARK: - Structured narration

    func testNarrationCardOmitsSectionsThatHaveNotStreamedYet() {
        let partial = NarrationCardContent(takeaway: "Dining is up.", whyItMatters: "", nextSteps: [])

        XCTAssertEqual(partial.markdown, "## Key Takeaway\n\nDining is up.")
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(NarrationCardContent(takeaway: "", whyItMatters: "", nextSteps: []).markdown, "")
    }

    func testCompleteNarrationCardNeedsAllThreeParts() {
        XCTAssertTrue(NarrationCardContent(takeaway: "a", whyItMatters: "b", nextSteps: ["c"]).isComplete)
        XCTAssertFalse(NarrationCardContent(takeaway: "a", whyItMatters: "b", nextSteps: [" "]).isComplete)
    }

    // MARK: - Figure grounding

    func testGroundingFindsOnlyCurrencyAmounts() {
        let text = "Dining is 180% over budget: $1,070.00 needed, 14 days left, 3 months, €12,50 and 45 USD."

        XCTAssertEqual(FigureGrounding.amounts(in: text), [dec("1070"), dec("12.5"), dec("45")])
    }

    func testGroundingParsesLocaleFormats() {
        for (raw, expected) in [("1,070.00", "1070"), ("1.070,00", "1070"), ("12,50", "12.5"), ("1070", "1070"), ("0.75", "0.75"), ("1,070", "1070"), ("1,070,000", "1070000")] {
            XCTAssertEqual(FigureGrounding.parse(raw), dec(expected), raw)
        }
    }

    func testGroundingAcceptsAmountsFromFactsAndToolResultsRegardlessOfFormat() {
        let facts = "- January 2024: $500.00 (Dining $300.00)"
        let toolResult = "Total: $1,070.00"

        XCTAssertTrue(FigureGrounding.ungroundedAmounts(in: "You spent $300 on dining, $500.00 overall and $1,070.00 in total.", sources: [facts, toolResult]).isEmpty)
    }

    func testGroundingFlagsInventedAmountsOnce() {
        let facts = "Dining $300.00, over budget by $80.00"

        let offenders = FigureGrounding.ungroundedAmounts(in: "$180.00 saved, then $180.00 again, plus $300.00 and $42", sources: [facts])

        XCTAssertEqual(offenders, [dec("180"), dec("42")])
    }

    func testGroundingIgnoresPlainNumbersThatAreNotAmounts() {
        XCTAssertTrue(FigureGrounding.ungroundedAmounts(in: "Over 14 days, 3 times, 25% more", sources: ["nothing"]).isEmpty)
    }

    func testToolOutputLogCollectsWhatToolsReturn() {
        let log = ToolOutputLog()
        log.record("a")
        log.record("b")

        XCTAssertEqual(log.outputs, ["a", "b"])
    }

    // MARK: - Ledger queries behind the tools

    func testCategoryTotalsComeFromTheLedgerNotTheModel() {
        let ledger = makeLedger()

        let january = ledger.categoryTotals(monthsAgo: 1)
        XCTAssertEqual(january.map(\.category), [.dining, .groceries])
        XCTAssertEqual(january.map(\.total), [dec("300"), dec("200")])
        XCTAssertEqual(ledger.categoryTotals(monthsAgo: 1, category: .groceries).map(\.total), [dec("200")])
        XCTAssertEqual(ledger.totalSpending(monthsAgo: 1), dec("500"))
    }

    func testCategoryTotalsIgnoreIncomeAndSavingsAndFutureDates() {
        let ledger = LedgerSnapshot(now: date(2024, 2, 15), calendar: utc, entries: [
            InsightFixtures.spend(100, .groceries, on: date(2024, 2, 1)),
            InsightFixtures.spend(900, .groceries, on: date(2024, 2, 2), kind: .income),
            InsightFixtures.spend(50, .savings, on: date(2024, 2, 3)),
            InsightFixtures.spend(70, .groceries, on: date(2024, 2, 20))
        ])

        XCTAssertEqual(ledger.categoryTotals(monthsAgo: 0).map(\.total), [dec("100")])
    }

    func testTransactionSearchMatchesMerchantsCaseAndAccentInsensitively() {
        let ledger = LedgerSnapshot(now: date(2024, 2, 15), calendar: utc, entries: [
            InsightFixtures.spend(4, .dining, merchant: "Café Nero", on: date(2024, 2, 1)),
            InsightFixtures.spend(5, .dining, merchant: "CAFE NERO", on: date(2024, 2, 9)),
            InsightFixtures.spend(30, .groceries, merchant: "Lidl", on: date(2024, 2, 5))
        ])

        let found = ledger.transactions(matching: "cafe nero")
        XCTAssertEqual(found.map(\.amount), [5, 4], "newest first")
        XCTAssertTrue(ledger.transactions(matching: "  ").isEmpty)
        XCTAssertEqual(ledger.transactions(matching: "cafe", limit: 1).count, 1)
    }

    func testTransactionSearchCapsResults() {
        let entries = (1...20).map { InsightFixtures.spend(Decimal($0), .dining, merchant: "Cafe", on: date(2024, 2, min($0, 14))) }
        let ledger = LedgerSnapshot(now: date(2024, 2, 15), calendar: utc, entries: entries)

        XCTAssertEqual(ledger.transactions(matching: "cafe", limit: 100).count, LedgerSnapshot.maximumSearchResults)
    }

    func testBudgetStatusReportsSpentLimitAndRemaining() {
        let ledger = LedgerSnapshot(
            now: date(2024, 2, 15), calendar: utc,
            entries: [
                InsightFixtures.spend(120, .dining, on: date(2024, 2, 3)),
                InsightFixtures.spend(40, .groceries, on: date(2024, 2, 4)),
                InsightFixtures.spend(999, .dining, on: date(2024, 1, 4))
            ],
            budgets: [BudgetLimit(category: .dining, limit: 100), BudgetLimit(category: .groceries, limit: 300)]
        )

        let lines = ledger.budgetStatus()
        XCTAssertEqual(lines.map(\.category), [.dining, .groceries], "most over-spent first")
        XCTAssertTrue(lines[0].isOver)
        XCTAssertEqual(lines[0].remaining, -20)
        XCTAssertEqual(lines[1].remaining, 260)
        XCTAssertEqual(ledger.budgetStatus(category: .groceries).count, 1)
    }

    func testToolTextQuotesCodeComputedFigures() {
        let ledger = makeLedger()

        let totals = LedgerText.categoryTotals(ledger, monthsAgo: 1, category: nil)
        XCTAssertTrue(totals.contains(LedgerText.money(300)))
        XCTAssertTrue(totals.contains("Total: \(LedgerText.money(500))"))
        XCTAssertTrue(LedgerText.categoryTotals(ledger, monthsAgo: 5, category: nil).hasPrefix("No spending"))
        XCTAssertTrue(LedgerText.transactions(ledger, matching: "zzz", limit: 3).contains("No transactions match"))
        XCTAssertTrue(LedgerText.budgetStatus(ledger, category: nil).contains("No budgets"))
    }

    #if canImport(FoundationModels)
    func testToolsAreNamedAndDescribedForTheModel() {
        let tools = LedgerTools.all(for: makeLedger())

        XCTAssertEqual(tools.map(\.name), ["categoryTotals", "transactions", "budgetStatus"])
        XCTAssertTrue(tools.allSatisfy { !$0.description.isEmpty })
    }

    func testToolCallsReturnLedgerText() async throws {
        let ledger = makeLedger()

        let log = ToolOutputLog()
        let totals = try await CategoryTotalsTool(ledger: ledger, log: log).call(arguments: .init(monthsAgo: 1, category: .dining))
        XCTAssertTrue(totals.contains(LedgerText.money(300)))
        XCTAssertEqual(log.outputs, [totals], "tool results are logged so their figures count as grounded")
        XCTAssertTrue(CategoryTotalsTool(ledger: ledger).description.contains("February 2024"), "the tool states which month is current")
        let search = try await TransactionSearchTool(ledger: ledger).call(arguments: .init(matching: "bistro", limit: 3))
        XCTAssertTrue(search.contains("Bistro"))
        let budgets = try await BudgetStatusTool(ledger: ledger).call(arguments: .init(category: nil))
        XCTAssertTrue(budgets.contains("No budgets"))
    }
    #endif

    // MARK: - Merchant normalization

    func testMerchantNameCleanerCleansBankStyleDescriptors() {
        let cases: [(String, String)] = [
            ("SQ *BLUE BOTTLE COFFEE #1234", "Blue Bottle Coffee"),
            ("AMZN Mktp US*2K4HG", "Amazon"),
            ("WAL-MART SUPERCENTER 5521", "Walmart"),
            ("UBER *EATS HELP.UBER.COM", "Uber Eats"),
            ("POS DEBIT SHELL OIL 57444", "Shell Oil"),
            ("  netflix.com  ", "Netflix"),
            ("TESCO STORES LTD", "Tesco Stores"),
            ("BP 4411", "BP")
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(MerchantNameCleaner.clean(raw), expected, raw)
        }
    }

    func testMerchantNameCleanerLeavesHandWrittenNamesAlone() {
        for name in ["Costa Coffee", "McDonald's", "iFixit", "Joe's Pizza", "7-Eleven"] {
            XCTAssertEqual(MerchantNameCleaner.clean(name), name)
        }
    }

    func testMerchantNameCleanerIsIdempotent() {
        for raw in ["SQ *BLUE BOTTLE COFFEE #1234", "AMZN Mktp US*2K4HG", "POS DEBIT SHELL OIL 57444", "", "   "] {
            let once = MerchantNameCleaner.clean(raw)
            XCTAssertEqual(MerchantNameCleaner.clean(once), once, raw)
        }
    }

    // MARK: - Auto-categorization

    func testKeywordRulesCategorizeCommonMerchants() {
        let cases: [(String, SpendingCategory)] = [
            ("Starbucks", .dining), ("SQ *BLUE BOTTLE COFFEE", .dining), ("Uber Eats", .dining), ("Uber", .transport),
            ("Whole Foods", .groceries), ("Lidl", .groceries), ("Netflix", .entertainment), ("Spotify", .entertainment),
            ("CVS Pharmacy", .health), ("Planet Fitness gym", .health), ("Shell", .transport), ("Comcast", .bills),
            ("Amazon", .shopping), ("Ryanair", .travel), ("Airbnb", .travel)
        ]
        for (merchant, expected) in cases {
            XCTAssertEqual(KeywordCategorizer.suggestion(merchant: merchant)?.category, expected, merchant)
            XCTAssertEqual(KeywordCategorizer.suggestion(merchant: merchant)?.source, .rule)
        }
    }

    func testKeywordRulesUseTheNoteWhenTheMerchantIsUnknown() {
        XCTAssertNil(KeywordCategorizer.suggestion(merchant: "Zorp Ltd"))
        XCTAssertEqual(KeywordCategorizer.suggestion(merchant: "Zorp Ltd", note: "team lunch")?.category, .dining)
    }

    func testKeywordRulesMatchWholeWordsOnly() {
        // "bar" must not fire inside "Barclays", "bus" not inside "Busch Gardens".
        XCTAssertNotEqual(KeywordCategorizer.suggestion(merchant: "Barclays")?.category, .dining)
        XCTAssertNil(KeywordCategorizer.suggestion(merchant: "Zzyzx"))
        XCTAssertNil(KeywordCategorizer.suggestion(merchant: ""))
    }

    #if canImport(FoundationModels)
    func testModelCategoriesMapOntoSpendingCategories() {
        let mapped = Set(SpendingCategoryChoice.allCases.map(\.category))

        XCTAssertEqual(mapped, Set(SpendingCategory.allCases).subtracting([.savings]))
        XCTAssertEqual(SpendingCategoryChoice.allCases.count, mapped.count, "no two choices collapse into one category")
        XCTAssertEqual(TransactionKindChoice.income.kind, .income)
        XCTAssertEqual(TransactionKindChoice.expense.kind, .expense)
    }
    #endif

    func testRuleBasedAssistantCategorizesWithoutAModel() async {
        let assistant = RuleBasedTransactionAssistant()

        let known = await assistant.suggestCategory(merchant: "Starbucks", note: "")
        let unknown = await assistant.suggestCategory(merchant: "Zorp Ltd", note: "")
        XCTAssertEqual(known, CategorySuggestion(category: .dining, source: .rule))
        XCTAssertNil(unknown)
    }

    func testCategorySuggestionFillsTheDraftUnlessTheUserChoseOne() async throws {
        let harness = try makeHarness(assistant: FixedAssistant(suggestion: CategorySuggestion(category: .travel, source: .model)))
        harness.context.prepareNewTransaction()
        harness.context.activeDraft.merchantName = "Zorp Ltd"

        await harness.context.suggestCategoryForActiveDraft()
        XCTAssertEqual(harness.context.activeDraft.category, .travel)
        XCTAssertEqual(harness.context.categorySuggestion?.source, .model)

        harness.context.activeDraft.category = .bills
        harness.context.activeDraft.categoryIsUserChosen = true
        await harness.context.suggestCategoryForActiveDraft()
        XCTAssertEqual(harness.context.activeDraft.category, .bills, "a manual choice is never overwritten")
    }

    func testCategorySuggestionSkipsIncomeAndEmptyMerchants() async throws {
        let harness = try makeHarness(assistant: FixedAssistant(suggestion: CategorySuggestion(category: .travel, source: .model)))
        harness.context.prepareNewTransaction()
        let original = harness.context.activeDraft.category

        await harness.context.suggestCategoryForActiveDraft()
        XCTAssertEqual(harness.context.activeDraft.category, original)

        harness.context.activeDraft.kind = .income
        harness.context.activeDraft.merchantName = "Acme"
        await harness.context.suggestCategoryForActiveDraft()
        XCTAssertEqual(harness.context.activeDraft.category, original)
    }

    func testNormalizingTheDraftMerchantOnlyChangesRawText() throws {
        let harness = try makeHarness()
        harness.context.activeDraft.merchantName = "SQ *BLUE BOTTLE COFFEE #12"
        harness.context.normalizeActiveMerchant()
        XCTAssertEqual(harness.context.activeDraft.merchantName, "Blue Bottle Coffee")

        harness.context.activeDraft.merchantName = "Costa Coffee"
        harness.context.normalizeActiveMerchant()
        XCTAssertEqual(harness.context.activeDraft.merchantName, "Costa Coffee")
    }

    // MARK: - Quick-add parsing contract

    private func parse(_ text: String, now: Date? = nil, locale: String = "en_US") -> QuickAddResult {
        // Wednesday 2024-03-13.
        QuickAddParser.parse(text, now: now ?? date(2024, 3, 13), calendar: utc, locale: Locale(identifier: locale))
    }

    func testQuickAddReadsTheCanonicalExample() {
        let result = parse("coffee 150 yesterday")

        XCTAssertEqual(result.amount, 150)
        XCTAssertEqual(result.kind, .expense)
        XCTAssertEqual(result.merchant, "Coffee")
        XCTAssertEqual(result.category, .dining)
        XCTAssertEqual(utc.startOfDay(for: result.date), utc.startOfDay(for: date(2024, 3, 12)))
        XCTAssertTrue(result.isComplete)
    }

    func testQuickAddAmountsAreExactDecimals() {
        XCTAssertEqual(parse("lunch 12.50").amount, dec("12.5"))
        XCTAssertEqual(parse("rent $1,250.75").amount, dec("1250.75"))
        XCTAssertEqual(parse("spent €45 at Lidl").amount, 45)
        XCTAssertEqual(parse("taxi 0.1").amount, dec("0.1"))
        XCTAssertEqual(parse("pizza 12,50", locale: "de_DE").amount, dec("12.5"))
    }

    func testQuickAddReadsRelativeAndNamedDates() {
        let wednesday = date(2024, 3, 13)
        func day(_ text: String) -> Date { utc.startOfDay(for: parse(text, now: wednesday).date) }
        func expected(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.startOfDay(for: date(y, m, d)) }

        XCTAssertEqual(day("coffee 4 today"), expected(2024, 3, 13))
        XCTAssertEqual(day("coffee 4"), expected(2024, 3, 13), "no date means today")
        XCTAssertEqual(day("coffee 4 day before yesterday"), expected(2024, 3, 11))
        XCTAssertEqual(day("coffee 4 3 days ago"), expected(2024, 3, 10))
        XCTAssertEqual(day("coffee 4 2 weeks ago"), expected(2024, 2, 28))
        XCTAssertEqual(day("coffee 4 last week"), expected(2024, 3, 6))
        XCTAssertEqual(day("coffee 4 on monday"), expected(2024, 3, 11))
        XCTAssertEqual(day("coffee 4 friday"), expected(2024, 3, 8))
        XCTAssertEqual(day("coffee 4 last wednesday"), expected(2024, 3, 6))
        XCTAssertEqual(day("coffee 4 wednesday"), expected(2024, 3, 13))
        XCTAssertEqual(day("coffee 4 2024-02-29"), expected(2024, 2, 29))
    }

    func testQuickAddNeverMistakesTheDatePhraseForTheAmount() {
        let result = parse("groceries 3 days ago 80")

        XCTAssertEqual(result.amount, 80)
        XCTAssertEqual(utc.startOfDay(for: result.date), utc.startOfDay(for: date(2024, 3, 10)))
    }

    func testQuickAddIgnoresStoreNumbersAndNumbersInNames() {
        let storeNumber = parse("sq *joes crab shack #44 62.40 2 days ago")
        XCTAssertEqual(storeNumber.amount, dec("62.4"))
        XCTAssertEqual(storeNumber.merchant, "Joes Crab Shack")

        XCTAssertEqual(parse("7-eleven 5.50").amount, dec("5.5"))
        XCTAssertEqual(parse("2 coffees 8.50").amount, dec("8.5"), "the last bare number wins")
        XCTAssertEqual(parse("4 coffees $9").amount, 9, "a currency symbol wins over position")
    }

    func testQuickAddFutureISODatesFallBackToToday() {
        XCTAssertEqual(utc.startOfDay(for: parse("coffee 4 2030-01-01").date), utc.startOfDay(for: date(2024, 3, 13)))
    }

    func testQuickAddCleansFillerWordsFromTheMerchant() {
        XCTAssertEqual(parse("spent 45 at whole foods").merchant, "Whole Foods")
        XCTAssertEqual(parse("paid $18 for netflix yesterday").merchant, "Netflix")
        XCTAssertEqual(parse("I bought 30 Uber").merchant, "Uber")
        XCTAssertEqual(parse("spent 45 at whole foods").category, .groceries)
    }

    func testQuickAddRecognisesIncomeAndTransfers() {
        let salary = parse("salary 3000 friday")
        XCTAssertEqual(salary.kind, .income)
        XCTAssertEqual(salary.amount, 3000)
        XCTAssertNil(salary.category, "income has no spending category")
        XCTAssertEqual(parse("transfer 200 to savings").kind, .transfer)
    }

    func testQuickAddReportsWhatItCouldNotRead() {
        XCTAssertNil(parse("coffee").amount)
        XCTAssertFalse(parse("coffee").isComplete)
        XCTAssertNil(parse("0 coffee").amount, "a zero amount isn't an amount")
        XCTAssertFalse(parse("150").isComplete, "an amount alone has no merchant")
    }

    func testQuickAddFillsATransactionDraft() {
        let result = parse("coffee 150 yesterday")
        let draft = TransactionDraft(quickAdd: result, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(draft.amount, 150)
        XCTAssertEqual(draft.merchantName, "Coffee")
        XCTAssertEqual(draft.category, .dining)
        XCTAssertEqual(draft.kind, .expense)
        XCTAssertEqual(draft.date, result.date)
        XCTAssertNil(draft.validationError)
    }

    func testQuickAddDraftUsesOtherWhenNoCategoryMatched() {
        let draft = TransactionDraft(quickAdd: parse("zorp 9"), locale: Locale(identifier: "en_US"))

        XCTAssertEqual(draft.category, .other)
    }

    func testModelReadingNeverChangesAmountOrDate() {
        let parsed = parse("coffee 150 yesterday")

        let merged = parsed.merging(QuickAddInterpretation(merchant: "STARBUCKS #12", kind: .expense, category: .dining))

        XCTAssertEqual(merged.amount, parsed.amount)
        XCTAssertEqual(merged.date, parsed.date)
        XCTAssertEqual(merged.merchant, "Starbucks")
    }

    func testModelReadingCanReclassifyButEmptyWordingKeepsTheParsedMerchant() {
        let parsed = parse("zorp 90 friday")

        let income = parsed.merging(QuickAddInterpretation(merchant: "", kind: .income, category: .dining))
        XCTAssertEqual(income.merchant, parsed.merchant)
        XCTAssertEqual(income.kind, .income)
        XCTAssertNil(income.category)

        let expense = parsed.merging(QuickAddInterpretation(merchant: "Zorp", kind: .expense, category: nil))
        XCTAssertEqual(expense.category, parsed.category)
    }

    func testApplyingQuickAddFillsTheActiveDraft() async throws {
        let harness = try makeHarness()
        harness.context.prepareNewTransaction()
        harness.context.activeDraft.locale = Locale(identifier: "en_US")

        let found = await harness.context.applyQuickAdd("uber 12.50 yesterday", now: date(2024, 3, 13))

        XCTAssertTrue(found)
        XCTAssertEqual(harness.context.activeDraft.amount, dec("12.5"))
        XCTAssertEqual(harness.context.activeDraft.merchantName, "Uber")
        XCTAssertEqual(harness.context.activeDraft.category, .transport)
        XCTAssertEqual(harness.context.categorySuggestion?.category, .transport)
        XCTAssertNil(harness.context.activeDraft.validationError)
    }

    func testApplyingQuickAddWithoutAnAmountSaysSoAndKeepsTheText() async throws {
        let harness = try makeHarness()
        harness.context.prepareNewTransaction()

        let found = await harness.context.applyQuickAdd("coffee yesterday", now: date(2024, 3, 13))

        XCTAssertFalse(found)
        XCTAssertEqual(harness.context.activeDraft.merchantName, "Coffee")
        XCTAssertNotNil(harness.context.activeDraft.validationError)
    }

    func testQuickAddThroughAMockAssistantFillsTheDraft() async throws {
        let canned = QuickAddResult(amount: 150, kind: .expense, merchant: "Mock Cafe", category: .dining, date: date(2024, 3, 12), remainder: "")
        let harness = try makeHarness(assistant: FixedAssistant(quickAdd: canned))
        harness.context.prepareNewTransaction()
        harness.context.activeDraft.locale = Locale(identifier: "en_US")

        await harness.context.applyQuickAdd("anything")

        XCTAssertEqual(harness.context.activeDraft.merchantName, "Mock Cafe")
        XCTAssertEqual(harness.context.activeDraft.amount, 150)
    }

    // MARK: - Helpers

    private struct Harness {
        let context: AppContext
        let modelContext: ModelContext
    }

    private func makeHarness(ai: AIInsightService = ScriptedAIService(behavior: .succeed), assistant: TransactionAssistant = RuleBasedTransactionAssistant()) throws -> Harness {
        let container = try ModelContainer(for: AppStoreSchema.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: ai,
            simulationService: DefaultSimulationService(),
            capabilityService: StaticCapabilityService(aiAvailability: .available),
            transactionAssistant: assistant
        )
        try context.bootstrap()
        return Harness(context: context, modelContext: modelContext)
    }

    /// A few months of spending ending today, so the engine has something to say.
    private func seedLedger(_ context: AppContext) throws {
        let calendar = Calendar.current
        let now = Date.now
        var draft = TransactionDraft()
        draft.locale = Locale(identifier: "en_US")
        for monthsBack in 0...3 {
            let month = calendar.date(byAdding: .month, value: -monthsBack, to: now) ?? now
            let day = monthsBack == 0 ? now : (calendar.date(bySetting: .day, value: 10, of: month) ?? month)
            for (amount, category, merchant) in [("400", SpendingCategory.groceries, "Lidl"), ("250", .dining, "Bistro"), ("90", .transport, "Metro")] {
                draft.amountText = amount
                draft.category = category
                draft.merchantName = merchant
                draft.date = day
                context.activeDraft = draft
                try context.saveDraft()
            }
        }
    }

    private func makeLedger() -> LedgerSnapshot {
        LedgerSnapshot(now: date(2024, 2, 15), calendar: utc, entries: [
            InsightFixtures.spend(200, .groceries, merchant: "Lidl", on: date(2024, 1, 5)),
            InsightFixtures.spend(300, .dining, merchant: "Bistro", on: date(2024, 1, 9)),
            InsightFixtures.spend(150, .groceries, merchant: "Lidl", on: date(2024, 2, 5)),
            InsightFixtures.spend(80, .dining, merchant: "Bistro", on: date(2024, 2, 9)),
            InsightFixtures.spend(100, .groceries, merchant: "Lidl", on: date(2023, 12, 5)),
            InsightFixtures.spend(60, .groceries, merchant: "Lidl", on: date(2023, 11, 5))
        ])
    }

    private func makeNarrationContext() -> NarrationContext {
        let ledger = makeLedger()
        let now = ledger.now
        let summary = DefaultSummaryService(calendar: utc).makeMonthlySummary(from: [], now: now)
        let insights = InsightFixtures.run(
            now: now, entries: ledger.entries,
            budgets: [BudgetLimit(category: .dining, limit: 50), BudgetLimit(category: .groceries, limit: 100)]
        )
        XCTAssertFalse(insights.isEmpty, "fixture should produce insights")
        return NarrationContext(summary: summary, insights: insights, ledger: ledger)
    }
}

/// Returns scripted outcomes and records what it was asked.
private final class ScriptedAIService: AIInsightService, @unchecked Sendable {
    enum Behavior {
        case succeed
        case unavailable(AIUnavailableReason)
        case fail(String)
    }

    let providerIdentifier = "scripted"
    private let lock = NSLock()
    private var _behavior: Behavior
    private var _calls = 0
    private var _lastContext: NarrationContext?

    init(behavior: Behavior) { _behavior = behavior }

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }
    var lastContext: NarrationContext? { lock.withLock { _lastContext } }

    func generateInsights(
        from context: NarrationContext,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload {
        lock.withLock {
            _calls += 1
            _lastContext = context
        }
        switch behavior {
        case .succeed:
            let cards = InsightKind.allCases.map { GeneratedInsightCard(kind: $0, markdown: "## Key Takeaway\n\n\($0.title)") }
            await onUpdate?(cards)
            return GeneratedInsightPayload(cards: cards, providerIdentifier: providerIdentifier)
        case .unavailable(let reason):
            throw AIInsightError.modelUnavailable(reason)
        case .fail(let message):
            throw AIInsightError.unavailable(message)
        }
    }

    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)?
    ) async throws -> GeneratedSimulationExplanation {
        GeneratedSimulationExplanation(markdown: "explained", providerIdentifier: providerIdentifier)
    }
}

/// A canned `TransactionAssistant`.
private struct FixedAssistant: TransactionAssistant {
    var suggestion: CategorySuggestion?
    var quickAdd: QuickAddResult?
    let providerIdentifier = "fixed"

    func suggestCategory(merchant: String, note: String) async -> CategorySuggestion? { suggestion }

    func parseQuickAdd(_ text: String, now: Date, calendar: Calendar, locale: Locale) async -> QuickAddResult {
        quickAdd ?? QuickAddParser.parse(text, now: now, calendar: calendar, locale: locale)
    }
}
