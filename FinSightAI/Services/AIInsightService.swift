import Foundation

protocol AIInsightService: Sendable {
    var providerIdentifier: String { get }
    /// Loads the model ahead of the first request so it answers faster. Safe to call repeatedly.
    func prewarm()
    func generateInsights(
        from context: NarrationContext,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload
    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)?
    ) async throws -> GeneratedSimulationExplanation
}

extension AIInsightService {
    func prewarm() {}
}

enum AIInsightError: LocalizedError, Equatable {
    /// Unavailable for a reason that isn't about the model itself.
    case unavailable(String)
    /// The model can't run on this device right now, with a reason the UI can explain.
    case modelUnavailable(AIUnavailableReason)
    case emptyResponse
    /// The narration quoted amounts that aren't in the user's data, even after a retry.
    case ungroundedFigures

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .modelUnavailable(let reason): reason.message
        case .emptyResponse: "The AI model returned an empty response."
        case .ungroundedFigures: "The AI narration quoted amounts that don't match your data, so it was hidden. The insights above are unaffected."
        }
    }

    /// Shown when the model failed or ran too long for a reason the user can't act on.
    static let narrationFailed = AIInsightError.unavailable(
        "The on-device AI couldn't finish the narration this time. The insights above are unaffected."
    )
}

/// Thrown by `withDeadline` when the operation runs past its time limit.
struct DeadlineExceeded: Error {}

/// Runs `operation`, cancelling it and throwing `DeadlineExceeded` if it hasn't finished within `limit`.
func withDeadline<T: Sendable>(
    _ limit: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

struct UnsupportedAIInsightService: AIInsightService {
    let reason: String
    let providerIdentifier = "unsupported"

    func generateInsights(
        from context: NarrationContext,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)? = nil
    ) async throws -> GeneratedInsightPayload {
        throw AIInsightError.unavailable(reason)
    }

    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)? = nil
    ) async throws -> GeneratedSimulationExplanation {
        throw AIInsightError.unavailable(reason)
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The three narration cards, generated together in one session. Properties are produced in
/// declaration order, so the cards fill in top to bottom as they stream.
@Generable(description: "Three short narrations of the user's month, each grounded in the supplied facts.")
struct InsightNarration {
    @Guide(description: "Budgeting: where spending is above or below plan, and one way to adjust.")
    var budgeting: NarrationCard
    @Guide(description: "Risk: rising expenses, concentration or recurring charges worth watching.")
    var risk: NarrationCard
    @Guide(description: "Growth: a realistic change that would help the user save more.")
    var growth: NarrationCard
}

@Generable(description: "One narration card.")
struct NarrationCard {
    @Guide(description: "The single most important point, in one sentence of at most 25 words.")
    var takeaway: String
    @Guide(description: "One or two sentences on why it matters. Quote only amounts from the facts or from tool results.")
    var whyItMatters: String
    @Guide(description: "Concrete next steps the user can take this week.", .count(1...2))
    var nextSteps: [String]
}

extension InsightNarration.PartiallyGenerated {
    /// The cards that have started streaming, as UI cards. Empty cards are skipped.
    var cards: [GeneratedInsightCard] {
        func card(_ kind: InsightKind, _ partial: NarrationCard.PartiallyGenerated?) -> GeneratedInsightCard? {
            guard let partial else { return nil }
            let content = NarrationCardContent(
                takeaway: partial.takeaway ?? "",
                whyItMatters: partial.whyItMatters ?? "",
                nextSteps: partial.nextSteps?.compactMap(\.self) ?? []
            )
            let markdown = content.markdown
            return markdown.isEmpty ? nil : GeneratedInsightCard(kind: kind, markdown: markdown)
        }
        return [card(.budgeting, budgeting), card(.risk, risk), card(.growth, growth)].compactMap { $0 }
    }
}

extension InsightNarration {
    var cards: [GeneratedInsightCard] {
        [(InsightKind.budgeting, budgeting), (.risk, risk), (.growth, growth)].map { kind, card in
            GeneratedInsightCard(
                kind: kind,
                markdown: NarrationCardContent(takeaway: card.takeaway, whyItMatters: card.whyItMatters, nextSteps: card.nextSteps).markdown
            )
        }
    }
}

struct AppleFoundationModelsInsightService: AIInsightService {
    let providerIdentifier = "apple-foundation-models"
    private let capabilityService: CapabilityService

    init(capabilityService: CapabilityService = DefaultCapabilityService()) {
        self.capabilityService = capabilityService
    }

    /// Checked on every call so a model that finishes downloading (or Apple Intelligence being
    /// switched on) is picked up by a retry without relaunching the app.
    private func ensureAvailable() throws {
        if case .unavailable(let reason) = capabilityService.aiAvailability {
            throw AIInsightError.modelUnavailable(reason)
        }
    }

    func prewarm() {
        guard capabilityService.aiAvailability.isAvailable else { return }
        LanguageModelSession(instructions: PromptFactory.narrationInstructions).prewarm()
    }

    func generateInsights(
        from context: NarrationContext,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)? = nil
    ) async throws -> GeneratedInsightPayload {
        try ensureAvailable()

        var budget = TokenBudget.promptBudget(contextSize: SystemLanguageModel.default.contextSize)
        var overflowRetries = 0
        var correction: String?
        var useTools = true
        do {
            while true {
                let log = ToolOutputLog()
                let tools = useTools ? LedgerTools.all(for: context.ledger, log: log) : []
                let prompt = await fittedPrompt(for: context, tools: tools, startingBudget: &budget)
                let request = prompt.text + (correction.map { "\n\n" + $0 } ?? "")
                do {
                    let payload = try await withDeadline(Self.attemptTimeLimit) {
                        try await stream(prompt: request, tools: tools, groundedIn: prompt.text, log: log, onUpdate: onUpdate)
                    }
                    let offenders = FigureGrounding.ungroundedAmounts(
                        in: payload.cards.map(\.markdown).joined(separator: "\n"),
                        sources: [prompt.text] + log.outputs
                    )
                    guard offenders.isEmpty else {
                        // One retry that names the offending amounts; after that, hide the narration
                        // rather than show figures the data doesn't support.
                        guard correction == nil else { throw AIInsightError.ungroundedFigures }
                        correction = Self.correction(for: offenders)
                        continue
                    }
                    return payload
                } catch where useTools && !Task.isCancelled && !(error is CancellationError) && !(error is AIInsightError) {
                    // Tool turns accumulate in the transcript and can overflow the context (the model
                    // reports this with error types that vary by OS) or run far too long. The facts
                    // already carry the key figures, so try once more without tools.
                    useTools = false
                } catch where Self.isContextOverflow(error) && overflowRetries < 2 {
                    // The estimate was too generous for this model: halve the budget and rebuild.
                    overflowRetries += 1
                    budget = max(TokenBudget.minimumPromptTokens, budget / 2)
                }
            }
        } catch let error as AIInsightError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AIInsightError.narrationFailed
        }
    }

    /// How long one narration attempt may run before it is abandoned.
    static let attemptTimeLimit: Duration = .seconds(90)

    private static func correction(for offenders: [Decimal]) -> String {
        let listed = offenders.map { LedgerText.money($0) }.joined(separator: ", ")
        return "Your previous answer used amounts that are not in the facts or tool results: \(listed). "
            + "Write it again using only amounts that appear in the facts or that a tool returned. "
            + "Do not add, subtract, round or estimate amounts."
    }

    private func stream(
        prompt: String,
        tools: [any Tool],
        groundedIn facts: String,
        log: ToolOutputLog,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload {
        let session = LanguageModelSession(tools: tools, instructions: PromptFactory.narrationInstructions)
        var latest: [GeneratedInsightCard] = []
        var isForwarding = onUpdate != nil

        for try await snapshot in session.streamResponse(to: prompt, generating: InsightNarration.self) {
            latest = snapshot.content.cards
            guard isForwarding else { continue }
            // Once a partial quotes an amount the data doesn't support, nothing more is shown from
            // this attempt; the full answer is still checked, retried or hidden below.
            isForwarding = FigureGrounding.ungroundedAmounts(
                inPartial: latest.map(\.markdown).joined(separator: "\n"),
                sources: [facts] + log.outputs
            ).isEmpty
            if isForwarding { await onUpdate?(latest) }
        }

        let cards = latest.map {
            GeneratedInsightCard(kind: $0.kind, markdown: $0.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard cards.count == InsightKind.allCases.count, cards.allSatisfy({ !$0.markdown.isEmpty }) else {
            throw AIInsightError.emptyResponse
        }
        return GeneratedInsightPayload(cards: cards, providerIdentifier: providerIdentifier)
    }

    /// Builds the grounding prompt within the estimated budget, then (where the OS can count tokens
    /// exactly) shrinks it further until the real count plus the response reserve fits the context.
    private func fittedPrompt(
        for context: NarrationContext,
        tools: [any Tool],
        startingBudget budget: inout Int
    ) async -> NarrationPrompt {
        var prompt = context.prompt(maxTokens: budget)
        guard #available(iOS 26.4, macOS 26.4, *) else { return prompt }
        let model = SystemLanguageModel.default
        let limit = model.contextSize - TokenBudget.responseReserve
        for _ in 0..<3 {
            guard let used = try? await Self.exactTokens(model: model, prompt: prompt.text, tools: tools), used > limit else {
                return prompt
            }
            budget = max(TokenBudget.minimumPromptTokens, budget - (used - limit) - 50)
            prompt = context.prompt(maxTokens: budget)
        }
        return prompt
    }

    @available(iOS 26.4, macOS 26.4, *)
    private static func exactTokens(model: SystemLanguageModel, prompt: String, tools: [any Tool]) async throws -> Int {
        try await model.tokenCount(for: prompt)
            + model.tokenCount(for: Instructions(PromptFactory.narrationInstructions))
            + model.tokenCount(for: tools)
            + model.tokenCount(for: InsightNarration.generationSchema)
    }

    @available(iOS, introduced: 26.0, deprecated: 27.0)
    @available(macOS, introduced: 26.0, deprecated: 27.0)
    private static func isContextOverflow(_ error: Error) -> Bool {
        if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
        // LanguageModelError only exists in the iOS 27 SDK (Swift 6.4 toolchain); CI builds with the iOS 26 SDK.
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), case LanguageModelError.contextSizeExceeded = error { return true }
        #endif
        return false
    }

    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)? = nil
    ) async throws -> GeneratedSimulationExplanation {
        try ensureAvailable()

        let session = LanguageModelSession(instructions: PromptFactory.simulationInstructions)
        let prompt = PromptFactory.simulationPrompt(input: input, projection: projection)
        var streamedMarkdown = ""

        for try await snapshot in session.streamResponse(to: prompt) {
            streamedMarkdown = snapshot.content
            await onUpdate?(streamedMarkdown)
        }

        let text = streamedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIInsightError.emptyResponse }
        return GeneratedSimulationExplanation(markdown: text, providerIdentifier: providerIdentifier)
    }
}
#endif

enum PromptFactory {
    static var narrationInstructions: String {
        """
        You are a personal finance assistant that narrates one month of spending in three short cards.
        The facts in the prompt come from the user's own ledger and are exact. Quote an amount only if it \
        appears word for word in the facts or in a tool result. Never add, subtract, round, estimate or \
        invent an amount, and never describe a spent amount as saved. For any figure that isn't listed, \
        call a tool and quote its result.
        Tools: categoryTotals (spending per category for a month), transactions (search by merchant), \
        budgetStatus (progress against budgets).
        Do not provide regulated financial advice. Be direct but constructive.

        Cards to write:
        - budgeting: \(InsightKind.budgeting.focus)
        - risk: \(InsightKind.risk.focus)
        - growth: \(InsightKind.growth.focus)
        """
    }

    static var simulationInstructions: String {
        """
        You explain savings simulations in plain language.
        Use the supplied numeric projection as the source of truth and do not change the numbers.
        Keep the response concise, practical, and educational.
        Return valid markdown with exactly these sections:
        ## Scenario Summary

        ## Tradeoff

        ## Recommended Next Step
        Put a blank line after each heading.
        Use one short paragraph under Scenario Summary and Tradeoff.
        Use 1-2 markdown bullet points under Recommended Next Step when the action is concrete.
        """
    }

    static func simulationPrompt(input: SimulationInput, projection: SimulationProjection) -> String {
        """
        Currency: \(CurrencyFormatter.currencyCode)
        Estimated monthly spending (full-month run-rate): \(CurrencyFormatter.string(from: input.monthlyRunRate))
        Recurring charges included in that spending: \(CurrencyFormatter.string(from: input.recurringMonthlySpend))
        Daily savings target: \(CurrencyFormatter.string(from: input.dailySavings))
        Spending reduction: \(PercentFormatter.string(from: input.reductionPercent / 100))
        Recurring charges paused: \(CurrencyFormatter.string(from: input.pausedRecurringMonthlySpend))
        Savings goal: \(CurrencyFormatter.string(from: input.savingsGoal))
        Monthly savings result: \(CurrencyFormatter.string(from: projection.monthlySavings))
        3-month projection: \(CurrencyFormatter.string(from: projection.projectedSavingsThreeMonths))
        6-month projection: \(CurrencyFormatter.string(from: projection.projectedSavingsSixMonths))
        12-month projection: \(CurrencyFormatter.string(from: projection.projectedSavingsTwelveMonths))
        Months to goal: \(projection.monthsToGoal.map(String.init) ?? "Not available")

        Explain the tradeoff and suggest one realistic next step without changing the numbers.
        """
    }
}
