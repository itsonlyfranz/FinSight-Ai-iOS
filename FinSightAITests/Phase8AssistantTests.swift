import SwiftData
import XCTest
@testable import FinSightAI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Phase 8: Ask FinSight. The deterministic FAQ fallback, the guardrails and disclaimer, the tool
/// wiring and the persisted transcript. The model is scripted; `OnDeviceModelSmokeTests` runs the real one.
@MainActor
final class Phase8AssistantTests: XCTestCase {
    private typealias F = InsightFixtures
    private let now = InsightFixtures.date(2026, 11, 15)

    private func money(_ value: Decimal) -> String { CurrencyFormatter.string(from: value) }

    // MARK: - Fixtures

    /// October and November spending, with a dining jump in October, plus a September baseline.
    private func ledger(budgets: [BudgetLimit] = []) -> LedgerSnapshot {
        let entries = [
            F.spend(1_000, .groceries, merchant: "SM Supermarket", on: F.date(2026, 9, 5)),
            F.spend(500, .dining, merchant: "Jollibee", on: F.date(2026, 9, 12)),
            F.spend(1_200, .groceries, merchant: "SM Supermarket", on: F.date(2026, 10, 5)),
            F.spend(3_500, .dining, merchant: "Sushi Omakase", on: F.date(2026, 10, 12)),
            F.spend(900, .transport, merchant: "Grab", on: F.date(2026, 10, 20)),
            F.spend(2_000, .groceries, merchant: "SM Supermarket", on: F.date(2026, 11, 3)),
            F.spend(18_000, .shopping, merchant: "Laptop Store", on: F.date(2026, 11, 8))
        ]
        return LedgerSnapshot(now: now, calendar: F.utc, entries: entries, budgets: budgets)
    }

    private func context(
        income: Decimal = 30_000,
        budgets: [BudgetLimit] = [],
        recurring: [AssistantContext.RecurringCharge] = [],
        goals: [AssistantContext.GoalLine] = [],
        insights: [Insight] = [],
        profile: UserProfile = UserProfile(),
        empty: Bool = false
    ) -> AssistantContext {
        let snapshot = empty ? LedgerSnapshot(now: now, calendar: F.utc, entries: []) : ledger(budgets: budgets)
        return AssistantContext(
            ledger: snapshot,
            summary: DefaultSummaryService(calendar: F.utc).makeMonthlySummary(from: [], now: now),
            insights: insights,
            monthlyIncome: income,
            recurringCharges: recurring,
            goals: goals,
            profile: profile
        )
    }

    private func netflix(upcoming: Bool) -> AssistantContext.RecurringCharge {
        .init(merchant: "Netflix", category: .entertainment, monthlyAmount: 549, expectedDate: F.date(2026, 11, 25), isUpcoming: upcoming)
    }

    // MARK: - FAQ fallback: matching

    func testQuestionsMapToTheRightQuickAnswer() {
        let cases: [(String, AssistantIntent)] = [
            ("Can I afford 8k this month?", .affordability(8_000)),
            ("Kaya ko bang gumastos ng ₱8,000 ngayong buwan?", .affordability(8_000)),
            ("Why was March so high?", .monthReview(monthsAgo: 8)),
            ("Bakit ang taas ng gastos noong Oktubre?", .monthReview(monthsAgo: 1)),
            ("How much did I spend last month?", .monthReview(monthsAgo: 1)),
            ("Why is my spending so high?", .monthReview(monthsAgo: 0)),
            ("How much have I spent this month?", .spending),
            ("Where is most of my money going?", .topCategories),
            ("Am I on track with my budgets?", .budgets),
            ("What subscriptions am I paying for?", .recurring),
            ("May subscriptions ba ako?", .recurring),
            ("How are my savings goals doing?", .goals),
            ("How can I save more this month?", .watchOuts),
            ("Hello", .greeting),
            ("Can I afford it?", .affordabilityWithoutAmount),
            ("Tell me a joke about penguins", .help)
        ]
        for (question, expected) in cases {
            XCTAssertEqual(AssistantFAQ.intent(for: question, now: now, calendar: F.utc), expected, question)
        }
    }

    func testEnglishMayIsOnlyAMonthInMonthPhrases() {
        XCTAssertEqual(AssistantMonthResolver.monthsAgo(in: "What did I spend in May?", now: now, calendar: F.utc), 6)
        XCTAssertEqual(AssistantMonthResolver.monthsAgo(in: "Bakit mataas noong Mayo?", now: now, calendar: F.utc), 6)
        XCTAssertNil(AssistantMonthResolver.monthsAgo(in: "May budget ba ako sa dining?", now: now, calendar: F.utc))
    }

    func testAmountsAreReadFromEverydayWriting() {
        XCTAssertEqual(AssistantAmountParser.amount(in: "8k"), 8_000)
        XCTAssertEqual(AssistantAmountParser.amount(in: "₱8,000"), 8_000)
        XCTAssertEqual(AssistantAmountParser.amount(in: "can I afford 8.5k?"), 8_500)
        XCTAssertEqual(AssistantAmountParser.amount(in: "PHP 12,500.50 for a phone"), F.dec("12500.5"))
        XCTAssertEqual(AssistantAmountParser.amount(in: "8 thousand"), 8_000)
        XCTAssertEqual(AssistantAmountParser.amount(in: "5 libo"), 5_000)
        XCTAssertEqual(AssistantAmountParser.amount(in: "In March 2026 can I afford 300?"), 300, "a year is not the amount")
        XCTAssertNil(AssistantAmountParser.amount(in: "can I afford a phone?"))
    }

    // MARK: - FAQ fallback: answers

    func testAffordabilityCountsSpendingAndRecurringChargesStillDue() {
        let base = context(income: 30_000, recurring: [netflix(upcoming: true), netflix(upcoming: false)])
        // Spent in November: 2,000 + 18,000 = 20,000; one Netflix (549) is still due; left 9,451.
        let tight = AffordabilityCheck.make(amount: 8_000, context: base)
        XCTAssertEqual(tight.spent, 20_000)
        XCTAssertEqual(tight.upcomingRecurring, 549)
        XCTAssertEqual(tight.leftBefore, 9_451)
        XCTAssertEqual(tight.leftAfter, 1_451)
        XCTAssertEqual(tight.verdict, .tight, "1,451 left is under a tenth of the 30,000 income")

        XCTAssertEqual(AffordabilityCheck.make(amount: 5_000, context: base).verdict, .comfortable)
        let short = AffordabilityCheck.make(amount: 10_000, context: base)
        XCTAssertEqual(short.verdict, .short)
        XCTAssertEqual(short.shortfall, 549)
        XCTAssertEqual(AffordabilityCheck.make(amount: 10, context: context(income: 0)).verdict, .noIncome)
    }

    func testAffordabilityAnswerQuotesTheWorkedOutFigures() {
        let answer = AssistantFAQ.answer(to: "Can I afford 8k this month?", context: context(income: 30_000))
        XCTAssertTrue(answer.contains(money(30_000)), answer)
        XCTAssertTrue(answer.contains(money(20_000)), answer)
        XCTAssertTrue(answer.contains(money(10_000)), "left before: \(answer)")
        XCTAssertTrue(answer.contains(money(2_000)), "left after: \(answer)")

        let shortAnswer = AssistantFAQ.answer(to: "Can I afford 12k?", context: context(income: 30_000))
        XCTAssertTrue(shortAnswer.contains(money(2_000)), "shortfall: \(shortAnswer)")
        XCTAssertTrue(shortAnswer.contains(SpendingCategory.shopping.localizedTitle), "suggests the top category: \(shortAnswer)")

        let noIncome = AssistantFAQ.answer(to: "Can I afford 8k?", context: context(income: 0))
        XCTAssertTrue(noIncome.contains("Settings"), noIncome)
    }

    func testMonthReviewExplainsWhatWentUp() {
        let review = MonthReview.make(monthsAgo: 1, ledger: ledger())
        XCTAssertEqual(review.total, 5_600)
        XCTAssertEqual(review.previousTotal, 1_500)
        XCTAssertEqual(review.change, 4_100)
        XCTAssertEqual(review.increases.map(\.category), [.dining, .transport, .groceries])
        XCTAssertEqual(review.increases.first?.change, 3_000)
        XCTAssertEqual(review.largestPurchases.first?.merchant, "Sushi Omakase")

        let answer = AssistantFAQ.answer(for: .monthReview(monthsAgo: 1), context: context())
        XCTAssertTrue(answer.contains(money(5_600)) && answer.contains(money(4_100)) && answer.contains(money(1_500)), answer)
        XCTAssertTrue(answer.contains("Sushi Omakase"), answer)
        XCTAssertTrue(answer.contains(SpendingCategory.dining.localizedTitle), answer)
    }

    func testQuickAnswersCoverBudgetsRecurringGoalsAndInsights() {
        let budgets = AssistantFAQ.answer(for: .budgets, context: context(budgets: [BudgetLimit(category: .shopping, limit: 10_000), BudgetLimit(category: .groceries, limit: 5_000)]))
        XCTAssertTrue(budgets.contains(money(8_000)), "shopping is 8,000 over: \(budgets)")
        XCTAssertTrue(budgets.contains(money(3_000)), "groceries has 3,000 left: \(budgets)")

        let recurring = AssistantFAQ.answer(for: .recurring, context: context(recurring: [netflix(upcoming: true)]))
        XCTAssertTrue(recurring.contains("Netflix") && recurring.contains(money(549)), recurring)

        let goals = AssistantFAQ.answer(for: .goals, context: context(goals: [.init(name: "Emergency Reserve", saved: 2_500, target: 10_000)]))
        XCTAssertTrue(goals.contains("Emergency Reserve") && goals.contains(money(2_500)) && goals.contains(money(10_000)), goals)

        let insights = F.run(now: now, entries: ledger().entries, budgets: [BudgetLimit(category: .shopping, limit: 10_000)])
        XCTAssertFalse(insights.isEmpty)
        let watchOuts = AssistantFAQ.answer(for: .watchOuts, context: context(insights: insights))
        XCTAssertTrue(watchOuts.contains(insights[0].title), watchOuts)

        let spending = AssistantFAQ.answer(for: .spending, context: context())
        XCTAssertTrue(spending.contains(money(20_000)) && spending.contains(SpendingCategory.shopping.localizedTitle), spending)
    }

    func testQuickAnswersWithoutDataAskForDataAndHelpListsSuggestions() {
        let empty = context(empty: true)
        XCTAssertFalse(empty.hasData)
        let answer = AssistantFAQ.answer(to: "How much have I spent this month?", context: empty)
        XCTAssertTrue(answer.contains("sample data"), answer)

        let help = AssistantFAQ.answer(to: "Tell me a joke", context: context())
        for prompt in AssistantSuggestions.prompts(for: context()) {
            XCTAssertTrue(help.contains(prompt), "help lists \(prompt)")
        }
        XCTAssertTrue(AssistantFAQ.answer(to: "hi", context: context(profile: UserProfile(name: "Mark Santos"))).contains("Mark Santos"))
    }

    func testSuggestedPromptsNameTheHighestRecentMonth() {
        let prompts = AssistantSuggestions.prompts(for: context())
        XCTAssertEqual(prompts.count, 6)
        let october = ledger().monthStart(monthsAgo: 1)
        XCTAssertEqual(AssistantSuggestions.highestRecentMonth(in: ledger()), october)
        XCTAssertEqual(prompts.first, String(localized: "Why was \(AssistantSuggestions.monthName(october)) so high?"))
        XCTAssertTrue(prompts.contains(String(localized: "Can I afford \(AssistantSuggestions.exampleAmountText) this month?")))
        XCTAssertEqual(AssistantFAQ.intent(for: prompts[0], now: now, calendar: F.utc), .monthReview(monthsAgo: 1))
        // Every suggestion gets a real quick answer, not the help text.
        for prompt in prompts {
            XCTAssertNotEqual(AssistantFAQ.intent(for: prompt, now: now, calendar: F.utc), .help, prompt)
        }
    }

    func testSuggestedMayPromptReviewsMay() {
        let may = LedgerSnapshot(now: now, calendar: F.utc, entries: [
            F.spend(9_000, .shopping, merchant: "Laptop Store", on: F.date(2026, 5, 10)),
            F.spend(1_000, .groceries, merchant: "SM Supermarket", on: F.date(2026, 10, 5))
        ])
        let context = AssistantContext(
            ledger: may,
            summary: DefaultSummaryService(calendar: F.utc).makeMonthlySummary(from: [], now: now),
            insights: [],
            monthlyIncome: 30_000,
            recurringCharges: [],
            goals: [],
            profile: UserProfile()
        )
        let prompt = AssistantSuggestions.prompts(for: context)[0]
        XCTAssertEqual(AssistantFAQ.intent(for: prompt, now: now, calendar: F.utc), .monthReview(monthsAgo: 6), prompt)
        // November back to May is six months, in English and in the Filipino suggestion wording.
        XCTAssertEqual(AssistantFAQ.intent(for: "Why was May so high?", now: now, calendar: F.utc), .monthReview(monthsAgo: 6))
        XCTAssertEqual(AssistantFAQ.intent(for: "Bakit ang taas ng gastos noong Mayo?", now: now, calendar: F.utc), .monthReview(monthsAgo: 6))
        XCTAssertEqual(AssistantFAQ.intent(for: "Bakit ang taas ng gastos noong Marso?", now: now, calendar: F.utc), .monthReview(monthsAgo: 8))
        XCTAssertEqual(AssistantFAQ.intent(for: "Why was March so high?", now: now, calendar: F.utc), .monthReview(monthsAgo: 8))
    }

    // MARK: - Guardrails and disclaimer

    func testOutOfScopeQuestionsAreScreenedBeforeAnyModel() {
        XCTAssertEqual(AssistantGuardrails.screen("Which stocks should I buy?"), .investmentPicks)
        XCTAssertEqual(AssistantGuardrails.screen("Should I put my savings into bitcoin?"), .investmentPicks)
        XCTAssertEqual(AssistantGuardrails.screen("How do I file my taxes?"), .taxOrLegal)
        XCTAssertEqual(AssistantGuardrails.screen("How can I launder money?"), .unlawful)
        XCTAssertNil(AssistantGuardrails.screen("Can I afford 8k this month?"))
        XCTAssertNil(AssistantGuardrails.screen("Is this Netflix charge fraud?"))
        XCTAssertNil(AssistantGuardrails.screen("How can I save more?"))
    }

    func testDisclaimerAppliesToMoneyAnswersOnly() {
        XCTAssertTrue(AssistantGuardrails.disclaimer.localizedCaseInsensitiveContains("not financial advice"))
        XCTAssertTrue(ChatReplyKind.answer.carriesDisclaimer)
        XCTAssertTrue(ChatReplyKind.quickAnswer.carriesDisclaimer)
        XCTAssertFalse(ChatReplyKind.guardrail.carriesDisclaimer)
        XCTAssertFalse(ChatReplyKind.refusal.carriesDisclaimer)
    }

    func testGuardrailRepliesNeverReachTheModel() async throws {
        let engine = ScriptedEngine(.answer("unused"))
        let service = OnDeviceAssistantService(engine: engine, capabilityService: StaticCapabilityService(aiAvailability: .available))
        let reply = try await service.reply(to: "What crypto should I invest in?", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(reply, AssistantReply(text: AssistantGuardrails.reply(for: .investmentPicks), kind: .guardrail))
        XCTAssertEqual(engine.calls.count, 0)

        let quick = try await QuickAnswerAssistantService().reply(to: "Help me with tax evasion", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(quick.kind, .guardrail)
    }

    func testModelRefusalAndSafetyBlocksAreShownAsSuch() async throws {
        let refused = try await service(ScriptedEngine(.fail(.refusal))).reply(to: "Write me a poem", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(refused, AssistantReply(text: AssistantGuardrails.modelRefusal, kind: .refusal))

        let blocked = try await service(ScriptedEngine(.fail(.guardrailViolation))).reply(to: "Something unsafe", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(blocked, AssistantReply(text: AssistantGuardrails.safetyBlocked, kind: .refusal))
    }

    #if canImport(FoundationModels)
    @available(iOS, introduced: 26.0, deprecated: 27.0)
    func testSystemErrorsMapToAssistantErrors() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "test")
        XCTAssertEqual(FoundationModelsAssistantEngine.engineError(for: LanguageModelSession.GenerationError.guardrailViolation(context)), .guardrailViolation)
        XCTAssertEqual(FoundationModelsAssistantEngine.engineError(for: LanguageModelSession.GenerationError.refusal(.init(transcriptEntries: []), context)), .refusal)
        XCTAssertEqual(FoundationModelsAssistantEngine.engineError(for: LanguageModelSession.GenerationError.exceededContextWindowSize(context)), .contextOverflow)
        XCTAssertEqual(FoundationModelsAssistantEngine.engineError(for: LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(context)), .unsupportedLanguage)
        XCTAssertEqual(FoundationModelsAssistantEngine.engineError(for: CocoaError(.featureUnsupported)), .failed)
    }
    #endif

    // MARK: - Model answers, grounding and fallback

    func testGroundedModelAnswerIsKeptAndStreams() async throws {
        // October's total is in the facts' month-by-month history.
        let engine = ScriptedEngine(.answer("In October you spent \(money(5_600)), mostly on Dining."))
        let partials = PartialRecorder()
        let reply = try await service(engine).reply(to: "How much did I spend in October?", history: [], context: context()) { await partials.add($0) }
        XCTAssertEqual(reply.kind, .answer)
        XCTAssertTrue(reply.text.contains(money(5_600)))
        let recorded = await partials.values
        XCTAssertFalse(recorded.isEmpty, "partials are forwarded while streaming")
        XCTAssertEqual(engine.calls.first?.instructions, AssistantPrompt.instructions)
    }

    func testQuotesAroundFiguresAreDroppedButQuotedWordsStay() {
        XCTAssertEqual(OnDeviceAssistantService.tidy("  You spent \"₱15,140.00\" in \"October\".  "), "You spent ₱15,140.00 in \"October\".")
        XCTAssertEqual(OnDeviceAssistantService.tidy("About “$1,200” a month"), "About $1,200 a month")
    }

    func testInventedAmountIsRetriedOnceThenReplacedByAQuickAnswer() async throws {
        let engine = ScriptedEngine(.answer("You could save \(money(12_345)) a month."))
        let reply = try await service(engine).reply(to: "How much have I spent this month?", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(engine.calls.count, 2, "one corrected retry")
        XCTAssertTrue(engine.calls[1].prompt.contains("not in the facts"), "the retry names the problem")
        XCTAssertEqual(reply.kind, .quickAnswer)
        XCTAssertTrue(reply.text.hasPrefix(OnDeviceAssistantService.unverifiedNote))
        XCTAssertTrue(reply.text.contains(money(20_000)), "the quick answer carries the real figure")
        XCTAssertFalse(reply.text.contains(money(12_345)))
    }

    func testFailuresRetryWithoutToolsThenFallBack() async throws {
        let engine = ScriptedEngine(.fail(.failed))
        let reply = try await service(engine).reply(to: "Where is most of my money going?", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(engine.calls.map(\.hadTools), [true, false])
        XCTAssertEqual(reply.kind, .quickAnswer)
        XCTAssertTrue(reply.text.hasPrefix(OnDeviceAssistantService.failedNote))
    }

    func testContextOverflowDropsTheChatHistoryFirst() async throws {
        let engine = ScriptedEngine(sequence: [.fail(.contextOverflow), .answer("Your budgets look fine.")])
        let history = [ChatMessage(role: .user, text: "Earlier question about rent"), ChatMessage(role: .assistant, text: "Earlier answer", replyKind: .answer)]
        let reply = try await service(engine).reply(to: "Am I on track?", history: history, context: context(), onPartial: nil)
        XCTAssertTrue(engine.calls[0].prompt.contains("Earlier question about rent"))
        XCTAssertFalse(engine.calls[1].prompt.contains("Earlier question about rent"))
        XCTAssertEqual(reply.kind, .answer)
    }

    func testUnsupportedLanguageFallsBackToAQuickAnswer() async throws {
        let reply = try await service(ScriptedEngine(.fail(.unsupportedLanguage))).reply(to: "Magkano na ang nagastos ko ngayong buwan?", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(reply.kind, .quickAnswer)
        XCTAssertTrue(reply.text.hasPrefix(OnDeviceAssistantService.languageNote))
        XCTAssertTrue(reply.text.contains(money(20_000)))
    }

    func testIneligibleDeviceGetsQuickAnswersWithoutTouchingTheModel() async throws {
        let engine = ScriptedEngine(.answer("unused"))
        let service = OnDeviceAssistantService(engine: engine, capabilityService: StaticCapabilityService(aiAvailability: .unavailable(.deviceNotEligible)))
        XCTAssertEqual(service.mode, .quickAnswers(.deviceNotEligible))
        service.prewarm()
        let reply = try await service.reply(to: "Can I afford 8k this month?", history: [], context: context(), onPartial: nil)
        XCTAssertEqual(reply.kind, .quickAnswer)
        XCTAssertEqual(reply.text, AssistantFAQ.answer(to: "Can I afford 8k this month?", context: context()))
        XCTAssertEqual(engine.calls.count, 0)
        XCTAssertEqual(engine.prewarmCount, 0)
    }

    // MARK: - Tool wiring

    func testToolOutputsGroundTheAnswer() async throws {
        // The model looks up affordability and quotes the "left after" figure, which isn't in the facts.
        let engine = ScriptedEngine(.useTool(.affordability(amount: 8_000), quoting: { "After that you'd have \(LedgerText.money(2_000)) left." }))
        let reply = try await service(engine).reply(to: "Can I afford 8k this month?", history: [], context: context(income: 30_000), onPartial: nil)
        XCTAssertEqual(reply.kind, .answer, reply.text)
        XCTAssertEqual(engine.calls.first?.toolOutputs.count, 1)
        XCTAssertTrue(engine.calls.first?.toolOutputs.first?.contains("Left after it: \(LedgerText.money(2_000))") == true)
    }

    func testToolboxRunsEveryLookupAgainstTheContextAndCapsCalls() {
        let toolbox = AssistantToolbox(context: context(income: 30_000, budgets: [BudgetLimit(category: .shopping, limit: 10_000)]))
        XCTAssertTrue(toolbox.output(for: .categoryTotals(monthsAgo: 0, category: nil)).contains(LedgerText.money(18_000)))
        XCTAssertTrue(toolbox.output(for: .transactions(matching: "sushi", limit: 3)).contains("Sushi Omakase"))
        XCTAssertTrue(toolbox.output(for: .budgetStatus(category: .shopping)).contains("over by \(LedgerText.money(8_000))"))
        XCTAssertTrue(toolbox.output(for: .monthReview(monthsAgo: 1)).contains("Difference: \(LedgerText.money(4_100)) more"))
        XCTAssertTrue(toolbox.output(for: .affordability(amount: 8_000)).contains("It fits"))

        for _ in 0..<AssistantToolbox.callLimit { _ = toolbox.run(.budgetStatus(category: nil)) }
        XCTAssertEqual(toolbox.run(.budgetStatus(category: nil)), AssistantToolbox.limitMessage)
        XCTAssertEqual(toolbox.log.outputs.count, AssistantToolbox.callLimit)
    }

    #if canImport(FoundationModels)
    func testFoundationModelsToolsAreTheToolboxLookups() async throws {
        let toolbox = AssistantToolbox(context: context(income: 30_000))
        let tools = AssistantTools.all(for: toolbox)
        XCTAssertEqual(tools.map(\.name), AssistantToolbox.toolNames)

        let review = try await MonthReviewTool(toolbox: toolbox).call(arguments: .init(monthsAgo: 1))
        XCTAssertEqual(review, toolbox.output(for: .monthReview(monthsAgo: 1)))
        let afford = try await AffordabilityTool(toolbox: toolbox).call(arguments: .init(amount: 8_000))
        XCTAssertEqual(afford, toolbox.output(for: .affordability(amount: 8_000)))
        let totals = try await CategoryTotalsTool(ledger: toolbox.context.ledger, log: toolbox.log).call(arguments: .init(monthsAgo: 0, category: nil))
        XCTAssertTrue(totals.contains(LedgerText.money(20_000)))
        XCTAssertEqual(toolbox.log.outputs, [review, afford, totals], "every tool records into the same log the answer is checked against")
    }
    #endif

    func testPromptCarriesFactsProfileAndHistoryWithinBudget() {
        let insights = F.run(now: now, entries: ledger().entries)
        let rich = context(
            recurring: [netflix(upcoming: true)],
            goals: [.init(name: "Emergency Reserve", saved: 2_500, target: 10_000)],
            insights: insights,
            profile: UserProfile(name: "Mark Santos", role: "Junior SWE @ Apex Systems")
        )
        let history = [ChatMessage(role: .user, text: "Why was October so high?"), ChatMessage(role: .assistant, text: "Dining went up.", replyKind: .answer)]
        let prompt = AssistantPrompt.make(question: "And this month?", history: history, context: rich, maxHistoryMessages: 4, maxTokens: 3_000)
        for expected in ["Mark Santos", "Junior SWE @ Apex Systems", LedgerText.money(30_000), "Netflix", "Emergency Reserve", "User: Why was October so high?", "FinSight: Dining went up.", "Question: And this month?"] {
            XCTAssertTrue(prompt.contains(expected), "missing \(expected)")
        }

        let tight = AssistantPrompt.make(question: "And this month?", history: history, context: rich, maxHistoryMessages: 4, maxTokens: 350)
        XCTAssertFalse(tight.contains("User: Why was October so high?"), "history goes first when space is short")
        XCTAssertTrue(tight.contains("Question: And this month?"))
    }

    // MARK: - Transcript persistence

    func testTranscriptIsSavedAndRestoredInOrder() async throws {
        let url = try temporaryStoreURL()
        do {
            let harness = try makeHarness(url: url)
            let reply = await harness.context.sendChatMessage("  Can I afford 8k this month?  ")
            XCTAssertEqual(reply?.kind, .quickAnswer)
            await harness.context.sendChatMessage("Which stocks should I buy?")
            XCTAssertEqual(harness.context.chatMessages.map(\.role), [.user, .assistant, .user, .assistant])
            XCTAssertFalse(harness.context.isAssistantResponding)
        }

        let reopened = try makeHarness(url: url)
        let messages = reopened.context.chatMessages
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(messages[0].text, "Can I afford 8k this month?", "stored trimmed")
        XCTAssertEqual(messages.map(\.replyKind), [nil, .quickAnswer, nil, .guardrail])
        XCTAssertEqual(messages[3].text, AssistantGuardrails.reply(for: .investmentPicks))
    }

    func testEmptyQuestionsAreIgnoredAndClearingDeletesTheTranscript() async throws {
        let harness = try makeHarness()
        let ignored = await harness.context.sendChatMessage("   ")
        XCTAssertNil(ignored)
        XCTAssertTrue(harness.context.chatMessages.isEmpty)

        await harness.context.sendChatMessage("Hello")
        XCTAssertEqual(try harness.modelContext.fetchCount(FetchDescriptor<ChatMessageRecord>()), 2)
        try harness.context.clearChat()
        XCTAssertTrue(harness.context.chatMessages.isEmpty)
        XCTAssertEqual(try harness.modelContext.fetchCount(FetchDescriptor<ChatMessageRecord>()), 0)
    }

    func testTranscriptKeepsOnlyTheNewestMessages() async throws {
        let harness = try makeHarness()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(AppContext.chatMessageLimit / 2 + 1) {
            await harness.context.sendChatMessage("Question \(index)", now: start.addingTimeInterval(Double(index) * 10))
        }
        XCTAssertEqual(harness.context.chatMessages.count, AppContext.chatMessageLimit)
        XCTAssertEqual(try harness.modelContext.fetchCount(FetchDescriptor<ChatMessageRecord>()), AppContext.chatMessageLimit)
        XCTAssertEqual(harness.context.chatMessages.first?.text, "Question 1", "the oldest exchange was dropped")
    }

    func testChatPassesHistoryAndTheLiveLedgerToTheAssistant() async throws {
        let recorder = RecordingAssistantService()
        let harness = try makeHarness(assistant: recorder)
        try harness.context.loadSampleData()
        await harness.context.sendChatMessage("First")
        await harness.context.sendChatMessage("Second")
        let calls = recorder.calls
        XCTAssertEqual(calls.map(\.question), ["First", "Second"])
        XCTAssertEqual(calls[1].history.map(\.text), ["First", "Recorded reply"])
        XCTAssertEqual(calls[1].context.ledger.totalSpending(monthsAgo: 0), harness.context.narrationLedger.totalSpending(monthsAgo: 0))
        XCTAssertEqual(harness.context.chatMessages.last?.replyKind, .answer)
    }

    func testStoreWrittenAsSchemaV4OpensAtV5WithAnEmptyTranscript() throws {
        let url = try temporaryStoreURL()
        let transactionID = UUID()
        do {
            let v4 = Schema(FinSightSchemaV4.models)
            let container = try ModelContainer(for: v4, configurations: ModelConfiguration(schema: v4, url: url))
            let context = ModelContext(container)
            context.insert(FinSightSchemaV2.TransactionRecord(id: transactionID, amount: F.dec("19.99"), merchantName: "Netflix", category: .entertainment, date: F.date(2026, 10, 10)))
            context.insert(FinSightSchemaV4.SavedScenarioRecord(name: "Plan", scenario: SimulationScenario()))
            try context.save()
        }

        let context = ModelContext(try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url)))
        XCTAssertEqual(try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.id), [transactionID])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedScenarioRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessageRecord>()), 0)
        context.insert(ChatMessageRecord(role: .user, text: "Hi"))
        try context.save()
        XCTAssertEqual(FinSightSchemaV5.models.count, FinSightSchemaV4.models.count + 1)
        XCTAssertEqual(FinSightMigrationPlan.schemas.last.map { ObjectIdentifier($0) }, ObjectIdentifier(FinSightSchemaV5.self))
    }

    func testDuplicateChatRowsAreRemoved() throws {
        let harness = try makeHarness()
        let id = UUID()
        harness.modelContext.insert(ChatMessageRecord(id: id, role: .user, text: "Hi"))
        harness.modelContext.insert(ChatMessageRecord(id: id, role: .user, text: "Hi"))
        try harness.modelContext.save()
        XCTAssertEqual(try StoreIntegrity.dedupe(in: harness.modelContext), 1)
        XCTAssertEqual(try harness.modelContext.fetchCount(FetchDescriptor<ChatMessageRecord>()), 1)
    }

    // MARK: - Helpers

    private func service(_ engine: ScriptedEngine) -> OnDeviceAssistantService {
        OnDeviceAssistantService(engine: engine, capabilityService: StaticCapabilityService(aiAvailability: .available))
    }

    private struct Harness {
        let context: AppContext
        let modelContext: ModelContext
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinSightChat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("store.sqlite")
    }

    private func makeHarness(url: URL? = nil, assistant: AssistantService = QuickAnswerAssistantService(reason: .deviceNotEligible)) throws -> Harness {
        let configuration = url.map { ModelConfiguration(schema: AppStoreSchema.schema, url: $0) } ?? ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try AppStoreSchema.makeContainer(configuration: configuration)
        let modelContext = ModelContext(container)
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: UnsupportedAIInsightService(reason: "test"),
            simulationService: DefaultSimulationService(),
            capabilityService: StaticCapabilityService(aiAvailability: .unavailable(.deviceNotEligible)),
            assistantService: assistant
        )
        try context.bootstrap()
        return Harness(context: context, modelContext: modelContext)
    }
}

// MARK: - Test doubles

/// Stands in for the language model: answers, fails or uses a tool as scripted, and records each call.
private final class ScriptedEngine: AssistantEngine, @unchecked Sendable {
    enum Step {
        case answer(String)
        case fail(AssistantEngineError)
        /// Runs a lookup through the toolbox, then answers with text built after the lookup.
        case useTool(AssistantToolbox.Call, quoting: @Sendable () -> String)
    }

    struct Call {
        let instructions: String
        let prompt: String
        let hadTools: Bool
        var toolOutputs: [String]
    }

    private let steps: [Step]
    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _prewarms = 0

    init(_ step: Step) { steps = [step] }
    init(sequence: [Step]) { steps = sequence }

    var calls: [Call] { lock.withLock { _calls } }
    var prewarmCount: Int { lock.withLock { _prewarms } }

    func prewarm(instructions: String) { lock.withLock { _prewarms += 1 } }

    func respond(instructions: String, prompt: String, toolbox: AssistantToolbox?, onPartial: (@Sendable (String) async -> Void)?) async throws -> String {
        let index = lock.withLock {
            _calls.append(Call(instructions: instructions, prompt: prompt, hadTools: toolbox != nil, toolOutputs: []))
            return _calls.count - 1
        }
        switch steps[min(index, steps.count - 1)] {
        case .answer(let text):
            let words = text.split(separator: " ")
            for count in 1...max(1, words.count) { await onPartial?(words.prefix(count).joined(separator: " ")) }
            return text
        case .fail(let error):
            throw error
        case .useTool(let call, let quoting):
            guard let toolbox else { throw AssistantEngineError.failed }
            let output = toolbox.run(call)
            lock.withLock { _calls[index].toolOutputs.append(output) }
            return quoting()
        }
    }
}

private actor PartialRecorder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

/// Records what the chat sends the assistant and replies with a fixed answer.
private final class RecordingAssistantService: AssistantService, @unchecked Sendable {
    struct Call {
        let question: String
        let history: [ChatMessage]
        let context: AssistantContext
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    let mode = AssistantMode.onDevice

    func reply(to question: String, history: [ChatMessage], context: AssistantContext, onPartial: (@Sendable (String) async -> Void)?) async throws -> AssistantReply {
        lock.withLock { _calls.append(Call(question: question, history: history, context: context)) }
        await onPartial?("Recorded")
        return AssistantReply(text: "Recorded reply", kind: .answer)
    }
}
