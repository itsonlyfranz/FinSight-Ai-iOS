import Foundation

/// One reply from Ask FinSight.
struct AssistantReply: Equatable, Sendable {
    let text: String
    let kind: ChatReplyKind
}

/// Whether the chat is answered by the on-device model or by quick answers alone.
enum AssistantMode: Equatable, Sendable {
    case onDevice
    /// The model can't run here (with the reason); questions get deterministic quick answers.
    case quickAnswers(AIUnavailableReason)

    var unavailableReason: AIUnavailableReason? {
        if case .quickAnswers(let reason) = self { return reason }
        return nil
    }
}

/// Answers chat questions. Never fails: when the model can't answer, the reply falls back to a
/// quick answer worked out from the user's data. Only cancellation is thrown.
protocol AssistantService: Sendable {
    var mode: AssistantMode { get }
    /// Loads the model ahead of the first question. Safe to call repeatedly.
    func prewarm()
    func reply(
        to question: String,
        history: [ChatMessage],
        context: AssistantContext,
        onPartial: (@Sendable (String) async -> Void)?
    ) async throws -> AssistantReply
}

extension AssistantService {
    func prewarm() {}
}

/// Quick answers only: the scope check, then the deterministic FAQ. What ineligible devices run.
struct QuickAnswerAssistantService: AssistantService {
    var reason: AIUnavailableReason = .unsupportedSDK

    var mode: AssistantMode { .quickAnswers(reason) }

    func reply(
        to question: String,
        history: [ChatMessage],
        context: AssistantContext,
        onPartial: (@Sendable (String) async -> Void)?
    ) async throws -> AssistantReply {
        if let topic = AssistantGuardrails.screen(question) {
            return AssistantReply(text: AssistantGuardrails.reply(for: topic), kind: .guardrail)
        }
        return AssistantReply(text: AssistantFAQ.answer(to: question, context: context), kind: .quickAnswer)
    }
}

// MARK: - Model engine

/// Why the model didn't produce an answer, independent of the OS's error types.
enum AssistantEngineError: Error, Equatable {
    /// The model declined to answer.
    case refusal
    /// Apple's safety checks blocked the prompt or the answer.
    case guardrailViolation
    case contextOverflow
    /// The question's language isn't supported by the on-device model.
    case unsupportedLanguage
    case failed
}

/// Runs one prompt through a language model. The app uses Foundation Models; tests script it.
protocol AssistantEngine: Sendable {
    /// Tokens the model can hold, prompt and answer together.
    var contextSize: Int { get }
    func prewarm(instructions: String)
    /// The full answer. `toolbox` is nil when the model must answer from the facts alone.
    /// `onPartial` receives the answer so far while it streams.
    func respond(
        instructions: String,
        prompt: String,
        toolbox: AssistantToolbox?,
        onPartial: (@Sendable (String) async -> Void)?
    ) async throws -> String
}

extension AssistantEngine {
    var contextSize: Int { 4096 }
    func prewarm(instructions: String) {}
}

/// The lookups the model can make while answering, all computed by code. The Foundation Models
/// tools are thin wrappers around `run(_:)`, so tests can exercise the same wiring without a model.
struct AssistantToolbox: Sendable {
    enum Call: Equatable, Sendable {
        case categoryTotals(monthsAgo: Int, category: SpendingCategory?)
        case transactions(matching: String, limit: Int)
        case budgetStatus(category: SpendingCategory?)
        case monthReview(monthsAgo: Int)
        case affordability(amount: Decimal)
    }

    /// Lookups per answer; the model is told to answer once they're used up.
    static let callLimit = 3
    static let limitMessage = "No more lookups are available. Answer now using the facts and the results you already have."
    /// The tool names the model sees, in the order they're offered.
    static let toolNames = ["categoryTotals", "transactions", "budgetStatus", "monthReview", "affordability"]

    let context: AssistantContext
    let log: ToolOutputLog

    init(context: AssistantContext, log: ToolOutputLog = ToolOutputLog(callLimit: AssistantToolbox.callLimit, limitMessage: AssistantToolbox.limitMessage)) {
        self.context = context
        self.log = log
    }

    /// Runs a lookup and records its output so the answer's amounts can be checked against it.
    func run(_ call: Call) -> String {
        log.record(output(for: call))
    }

    func output(for call: Call) -> String {
        switch call {
        case .categoryTotals(let monthsAgo, let category):
            LedgerText.categoryTotals(context.ledger, monthsAgo: min(max(0, monthsAgo), 11), category: category)
        case .transactions(let matching, let limit):
            LedgerText.transactions(context.ledger, matching: matching, limit: limit)
        case .budgetStatus(let category):
            LedgerText.budgetStatus(context.ledger, category: category)
        case .monthReview(let monthsAgo):
            AssistantText.monthReview(MonthReview.make(monthsAgo: monthsAgo, ledger: context.ledger))
        case .affordability(let amount):
            AssistantText.affordability(AffordabilityCheck.make(amount: amount, context: context))
        }
    }
}

// MARK: - On-device assistant

/// The on-device model with the app's guardrails around it: a scope check before the model, tools
/// for every lookup, an amount check after it, and a quick answer whenever the model can't help.
struct OnDeviceAssistantService: AssistantService {
    /// How long one attempt may run before it is abandoned.
    static let attemptTimeLimit: Duration = .seconds(60)

    private let engine: any AssistantEngine
    private let capabilityService: CapabilityService

    init(engine: any AssistantEngine, capabilityService: CapabilityService = DefaultCapabilityService()) {
        self.engine = engine
        self.capabilityService = capabilityService
    }

    /// Checked on every question so Apple Intelligence being switched on (or the model finishing its
    /// download) is picked up without relaunching.
    var mode: AssistantMode {
        switch capabilityService.aiAvailability {
        case .available: .onDevice
        case .unavailable(let reason): .quickAnswers(reason)
        }
    }

    func prewarm() {
        guard mode == .onDevice else { return }
        engine.prewarm(instructions: AssistantPrompt.instructions)
    }

    func reply(
        to question: String,
        history: [ChatMessage],
        context: AssistantContext,
        onPartial: (@Sendable (String) async -> Void)?
    ) async throws -> AssistantReply {
        if let topic = AssistantGuardrails.screen(question) {
            return AssistantReply(text: AssistantGuardrails.reply(for: topic), kind: .guardrail)
        }
        guard mode == .onDevice else {
            return AssistantReply(text: AssistantFAQ.answer(to: question, context: context), kind: .quickAnswer)
        }

        var historyMessages = AssistantPrompt.maximumHistoryMessages
        var useTools = true
        var correction: String?
        let budget = TokenBudget.promptBudget(contextSize: engine.contextSize)
        let questionAmounts = AssistantAmountParser.amount(in: question).map { [LedgerText.money($0)] } ?? []

        while true {
            try Task.checkCancellation()
            let toolbox = AssistantToolbox(context: context)
            let prompt = AssistantPrompt.make(question: question, history: history, context: context, maxHistoryMessages: historyMessages, maxTokens: budget)
            let sources = [prompt, question] + questionAmounts
            let forwarder = PartialForwarder(sources: sources, log: toolbox.log, onPartial: onPartial)
            let request = prompt + (correction.map { "\n\n" + $0 } ?? "")
            do {
                let engine = self.engine
                let attemptToolbox: AssistantToolbox? = useTools ? toolbox : nil
                let forward: (@Sendable (String) async -> Void)? = onPartial == nil ? nil : { @Sendable partial in await forwarder.forward(partial) }
                let answer = try await withDeadline(Self.attemptTimeLimit) {
                    try await engine.respond(
                        instructions: AssistantPrompt.instructions,
                        prompt: request,
                        toolbox: attemptToolbox,
                        onPartial: forward
                    )
                }
                let text = Self.tidy(answer)
                guard !text.isEmpty else { return fallback(question, context, note: Self.failedNote) }
                let offenders = FigureGrounding.ungroundedAmounts(in: text, sources: sources + toolbox.log.outputs)
                guard offenders.isEmpty else {
                    // One retry that names the offending amounts; after that, answer from code.
                    guard correction == nil else { return fallback(question, context, note: Self.unverifiedNote) }
                    correction = Self.correction(for: offenders)
                    continue
                }
                return AssistantReply(text: text, kind: .answer)
            } catch let error as AssistantEngineError {
                switch error {
                case .refusal:
                    return AssistantReply(text: AssistantGuardrails.modelRefusal, kind: .refusal)
                case .guardrailViolation:
                    return AssistantReply(text: AssistantGuardrails.safetyBlocked, kind: .refusal)
                case .unsupportedLanguage:
                    return fallback(question, context, note: Self.languageNote)
                case .contextOverflow where historyMessages > 0:
                    historyMessages = 0
                case .contextOverflow, .failed:
                    // Tool turns can overflow the small context or run long; the facts carry the
                    // key figures, so try once more without tools before answering from code.
                    guard useTools else { return fallback(question, context, note: Self.failedNote) }
                    useTools = false
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard useTools, !(error is DeadlineExceeded) else { return fallback(question, context, note: Self.failedNote) }
                useTools = false
            }
        }
    }

    /// Trims the answer and drops quotation marks the model sometimes puts around figures
    /// ("\"₱1,200.00\"" becomes "₱1,200.00").
    static func tidy(_ answer: String) -> String {
        answer
            .replacingOccurrences(of: #"["“”]([^"“”\s]*\d[^"“”\s]*)["“”]"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fallback(_ question: String, _ context: AssistantContext, note: String) -> AssistantReply {
        AssistantReply(text: note + "\n\n" + AssistantFAQ.answer(to: question, context: context), kind: .quickAnswer)
    }

    static var failedNote: String {
        String(localized: "The on-device AI couldn't answer this time, so here's a quick answer from your data.")
    }

    static var unverifiedNote: String {
        String(localized: "I couldn't match the AI's numbers to your data, so here's a quick answer worked out from it instead.")
    }

    static var languageNote: String {
        String(localized: "The on-device AI doesn't support this language yet, so here's a quick answer from your data.")
    }

    private static func correction(for offenders: [Decimal]) -> String {
        let listed = offenders.map { LedgerText.money($0) }.joined(separator: ", ")
        return "Your previous answer used amounts that are not in the facts or tool results: \(listed). "
            + "Answer again using only amounts that appear in the facts or that a tool returned. "
            + "Do not add, subtract, round or estimate amounts."
    }
}

/// Passes streaming text on until it quotes an amount the data doesn't support; nothing more from
/// that attempt is shown after that (the final answer is still checked, retried or replaced).
private final class PartialForwarder: @unchecked Sendable {
    private let sources: [String]
    private let log: ToolOutputLog
    private let onPartial: (@Sendable (String) async -> Void)?
    private let lock = NSLock()
    private var isForwarding = true

    init(sources: [String], log: ToolOutputLog, onPartial: (@Sendable (String) async -> Void)?) {
        self.sources = sources
        self.log = log
        self.onPartial = onPartial
    }

    func forward(_ partial: String) async {
        let grounded = FigureGrounding.ungroundedAmounts(inPartial: partial, sources: sources + log.outputs).isEmpty
        let shouldForward = lock.withLock {
            if !grounded { isForwarding = false }
            return isForwarding
        }
        if shouldForward { await onPartial?(partial) }
    }
}

// MARK: - Prompt

/// The assistant's persona and the facts each question is grounded in.
enum AssistantPrompt {
    /// Earlier chat messages carried into the prompt, newest last.
    static let maximumHistoryMessages = 4
    /// Each carried message is cut to this many characters.
    static let maximumHistoryCharacters = 360
    static let maximumInsights = 4
    static let maximumRecurringCharges = 6

    /// The FinSight AI persona, adapted from the Android app's "intelligent financial decision-making
    /// for early-career earners" positioning and its insight voice (risk nudges, growth focus,
    /// actionable suggestions).
    static var instructions: String {
        """
        You are FinSight AI, the on-device money coach in the FinSight AI app: intelligent financial \
        decision-making for early-career earners and young professionals. Raw transaction numbers rarely \
        change habits, so turn the user's own data into clear, actionable nudges.
        Answer questions about the user's spending, income, budgets, savings goals and recurring charges.
        The facts in the prompt come from the user's own ledger and are exact. Quote an amount only if it \
        appears in the facts or in a tool result. Never add, subtract, round, estimate or invent an amount. \
        For any figure that isn't listed, call a tool and quote its result. Write amounts plainly, without \
        quotation marks.
        Tools: categoryTotals (spending per category for a month), transactions (search by merchant), \
        budgetStatus (this month's budgets), monthReview (why a month was higher or lower than the one \
        before), affordability (whether an amount fits in what is left this month).
        Keep answers short: two to four sentences, then at most two bullet points with an actionable \
        suggestion. Be direct but constructive and encouraging, never judgmental.
        You give general money guidance, not regulated financial advice. Never recommend specific stocks, \
        funds, crypto or other investments, and never give tax or legal advice; suggest a licensed \
        professional instead. If a question isn't about the user's money, say briefly that you can only \
        help with their finances.
        """
    }

    /// The prompt for one question, trimmed to `maxTokens`: older chat history goes first, then the
    /// month-by-month history, then the lower-ranked insights.
    static func make(question: String, history: [ChatMessage], context: AssistantContext, maxHistoryMessages: Int, maxTokens: Int) -> String {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullMonths = NarrationContext.historyMonths
        // Each step gives up a little more: chat messages, then history months, then insights.
        let steps: [(months: Int, insights: Int, messages: Int)] =
            stride(from: max(0, maxHistoryMessages), through: 0, by: -1).map { (fullMonths, maximumInsights, $0) }
            + stride(from: fullMonths - 1, through: 0, by: -1).map { ($0, maximumInsights, 0) }
            + stride(from: maximumInsights - 1, through: 0, by: -1).map { (0, $0, 0) }
        var candidate = ""
        for step in steps {
            candidate = assemble(
                question: trimmedQuestion,
                facts: facts(context: context, historyMonths: step.months, insightLimit: step.insights),
                history: Array(history.suffix(step.messages))
            )
            if TokenBudget.estimate(candidate) <= maxTokens { return candidate }
        }
        return candidate
    }

    static func facts(context: AssistantContext, historyMonths: Int, insightLimit: Int) -> String {
        var lines: [String] = []
        lines.append("Today: \(context.now.formatted(.dateTime.year().month(.wide).day().locale(Locale(identifier: "en_US")))).")
        if !context.profile.name.isEmpty { lines.append("The user's name: \(context.profile.name).") }
        if !context.profile.role.isEmpty { lines.append("The user's role: \(context.profile.role).") }
        guard context.hasData else {
            lines.append("No transactions are logged yet.")
            return lines.joined(separator: "\n")
        }
        var header = NarrationContext.header(summary: context.summary, ledger: context.ledger, historyMonths: historyMonths)
            .components(separatedBy: "\n")
        // The header ends with the insights heading; the insights follow below.
        if header.last?.hasPrefix("Insights") == true { header.removeLast() }
        lines += header
        if context.monthlyIncome > 0 {
            lines.append("This month's income: \(LedgerText.money(context.monthlyIncome)). Recurring charges still due this month: \(LedgerText.money(context.upcomingRecurringTotal)).")
        } else {
            lines.append("No income is recorded for this month.")
        }
        lines.append(AssistantText.recurring(Array(context.recurringCharges.prefix(maximumRecurringCharges))))
        lines.append(AssistantText.goals(context.goals))
        let insights = context.insights.prefix(insightLimit)
        if !insights.isEmpty {
            lines.append("Insights found by the app, most important first:")
            lines += insights.map(NarrationContext.line(for:))
        }
        return lines.joined(separator: "\n")
    }

    private static func assemble(question: String, facts: String, history: [ChatMessage]) -> String {
        var sections = ["Facts from the user's ledger:\n" + facts]
        if !history.isEmpty {
            let turns = history.map { message in
                let speaker = message.role == .user ? "User" : "FinSight"
                let text = message.text.count > maximumHistoryCharacters
                    ? String(message.text.prefix(maximumHistoryCharacters)) + "…"
                    : message.text
                return "\(speaker): \(text)"
            }
            sections.append("Recent conversation:\n" + turns.joined(separator: "\n"))
        }
        sections.append("Question: \(question)\nAnswer using the facts, the conversation and the tools.")
        return sections.joined(separator: "\n\n")
    }
}
