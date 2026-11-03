import Foundation

protocol AIInsightService: Sendable {
    var providerIdentifier: String { get }
    func generateInsights(
        from summary: MonthlySummary,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload
    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)?
    ) async throws -> GeneratedSimulationExplanation
}

enum AIInsightError: LocalizedError {
    case unavailable(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .emptyResponse: "The AI model returned an empty response."
        }
    }
}

struct UnsupportedAIInsightService: AIInsightService {
    let reason: String
    let providerIdentifier = "unsupported"

    func generateInsights(
        from summary: MonthlySummary,
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

/// All three insight cards come back from a single model call.
@Generable
struct InsightBundle {
    @Guide(description: "Budgeting insight as markdown with the headings Key Takeaway, Why It Matters and Next Step.")
    var budgeting: String
    @Guide(description: "Risk insight as markdown with the headings Key Takeaway, Why It Matters and Next Step.")
    var risk: String
    @Guide(description: "Growth insight as markdown with the headings Key Takeaway, Why It Matters and Next Step.")
    var growth: String
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
        if case .unavailable(let message) = capabilityService.aiAvailability {
            throw AIInsightError.unavailable(message)
        }
    }

    func generateInsights(
        from summary: MonthlySummary,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)? = nil
    ) async throws -> GeneratedInsightPayload {
        try ensureAvailable()

        let session = LanguageModelSession(instructions: PromptFactory.bundleInstructions)
        let prompt = PromptFactory.bundlePrompt(summary: summary)
        var latest: [GeneratedInsightCard] = []

        for try await snapshot in session.streamResponse(to: prompt, generating: InsightBundle.self) {
            let partial = snapshot.content
            latest = InsightKind.allCases.compactMap { kind in
                let text: String?
                switch kind {
                case .budgeting: text = partial.budgeting
                case .risk: text = partial.risk
                case .growth: text = partial.growth
                }
                guard let text, !text.isEmpty else { return nil }
                return GeneratedInsightCard(kind: kind, markdown: text)
            }
            await onUpdate?(latest)
        }

        let cards = latest.map {
            GeneratedInsightCard(kind: $0.kind, markdown: $0.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard cards.count == InsightKind.allCases.count, cards.allSatisfy({ !$0.markdown.isEmpty }) else {
            throw AIInsightError.emptyResponse
        }
        return GeneratedInsightPayload(cards: cards, providerIdentifier: providerIdentifier)
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
    static func instructions(for kind: InsightKind) -> String {
        switch kind {
        case .budgeting:
            """
            You are a financial budgeting assistant.
            Analyze processed monthly spending patterns, highlight overspending categories or anomalies, and give concise, practical suggestions.
            Keep the tone clear, specific, and educational. Do not provide regulated financial advice.
            Return valid markdown with exactly these sections:
            ## Key Takeaway

            ## Why It Matters

            ## Next Step
            Put a blank line after each heading.
            Use one short paragraph under the first two headings.
            Use 1-2 markdown bullet points under Next Step when the action is concrete.
            """
        case .risk:
            """
            You are a financial risk analyst.
            Review monthly spending summaries for risk signals such as rising expenses, weak savings behavior, or concentration in volatile categories.
            Be direct but constructive. Do not provide regulated financial advice.
            Return valid markdown with exactly these sections:
            ## Key Takeaway

            ## Why It Matters

            ## Next Step
            Put a blank line after each heading.
            Use one short paragraph under the first two headings.
            Use 1-2 markdown bullet points under Next Step when the action is concrete.
            """
        case .growth:
            """
            You are a financial growth coach.
            Suggest realistic improvements that help the user save more or redirect spending more effectively.
            Keep the response actionable, concise, and grounded in the supplied summary.
            Return valid markdown with exactly these sections:
            ## Key Takeaway

            ## Why It Matters

            ## Next Step
            Put a blank line after each heading.
            Use one short paragraph under the first two headings.
            Use 1-2 markdown bullet points under Next Step when the action is concrete.
            """
        }
    }

    static var bundleInstructions: String {
        """
        You are a personal finance assistant that writes three short insights about one month of spending.
        Use only the supplied numbers; never change them. Do not provide regulated financial advice.
        Write each insight as valid markdown with exactly these sections:
        ## Key Takeaway

        ## Why It Matters

        ## Next Step
        Put a blank line after each heading.
        Use one short paragraph under the first two headings.
        Use 1-2 markdown bullet points under Next Step when the action is concrete.

        Insights to write:
        - budgeting: \(InsightKind.budgeting.focus)
        - risk: \(InsightKind.risk.focus)
        - growth: \(InsightKind.growth.focus)
        """
    }

    static func bundlePrompt(summary: MonthlySummary) -> String {
        """
        \(summaryFacts(for: summary))

        Write the budgeting, risk and growth insights tailored to this summary.
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

    static func insightPrompt(for kind: InsightKind, summary: MonthlySummary) -> String {
        """
        \(summaryFacts(for: summary))

        Write one concise \(kind.title.lowercased()) insight tailored to this summary.
        """
    }

    private static func summaryFacts(for summary: MonthlySummary) -> String {
        """
        Currency: \(CurrencyFormatter.currencyCode)
        Month: \(summary.monthLabel)
        Total spent: \(CurrencyFormatter.string(from: summary.totalSpent))
        Recurring monthly spend: \(CurrencyFormatter.string(from: summary.recurringMonthlySpend))
        Recurring item count: \(summary.recurringTransactionCount)
        Largest recurring merchant: \(summary.largestRecurringMerchant ?? "None")
        One-off spending this month: \(CurrencyFormatter.string(from: summary.oneOffSpent))
        Transaction count: \(summary.transactionCount)
        Average transaction: \(CurrencyFormatter.string(from: summary.averageTransactionValue))
        Top category: \(summary.topCategory?.title ?? "None")
        Top category share: \(PercentFormatter.string(from: summary.topCategoryShare))
        Trend: \(summary.spendingTrendDescription)
        Category breakdown:
        \(summary.categoryBreakdown.map { "- \($0.category.title): \(CurrencyFormatter.string(from: $0.amount)) (\(PercentFormatter.string(from: $0.percentage)))" }.joined(separator: "\n"))
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
