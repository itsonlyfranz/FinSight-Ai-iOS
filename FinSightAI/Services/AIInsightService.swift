import Foundation

protocol AIInsightService {
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

@available(iOS 26.0, *)
struct AppleFoundationModelsInsightService: AIInsightService {
    let providerIdentifier = "apple-foundation-models"

    func generateInsights(
        from summary: MonthlySummary,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)? = nil
    ) async throws -> GeneratedInsightPayload {
        var cards: [GeneratedInsightCard] = []

        for kind in InsightKind.allCases {
            let prompt = PromptFactory.insightPrompt(for: kind, summary: summary)
            let session = LanguageModelSession(instructions: PromptFactory.instructions(for: kind))
            var streamedMarkdown = ""

            for try await snapshot in session.streamResponse(to: prompt) {
                streamedMarkdown = snapshot.content
                let partialCards = cards + [GeneratedInsightCard(kind: kind, markdown: streamedMarkdown)]
                await onUpdate?(partialCards)
            }

            let text = streamedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIInsightError.emptyResponse }
            cards.append(GeneratedInsightCard(kind: kind, markdown: text))
            await onUpdate?(cards)
        }

        return GeneratedInsightPayload(cards: cards, providerIdentifier: providerIdentifier)
    }

    func explainSimulation(
        input: SimulationInput,
        projection: SimulationProjection,
        onUpdate: (@Sendable (String) async -> Void)? = nil
    ) async throws -> GeneratedSimulationExplanation {
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
        Month: \(summary.monthLabel)
        Total spent: \(CurrencyFormatter.pesoString(from: summary.totalSpent))
        Transaction count: \(summary.transactionCount)
        Average transaction: \(CurrencyFormatter.pesoString(from: summary.averageTransactionValue))
        Top category: \(summary.topCategory?.title ?? "None")
        Top category share: \(PercentFormatter.string(from: summary.topCategoryShare))
        Trend: \(summary.spendingTrendDescription)
        Category breakdown:
        \(summary.categoryBreakdown.map { "- \($0.category.title): \(CurrencyFormatter.pesoString(from: $0.amount)) (\(PercentFormatter.string(from: $0.percentage)))" }.joined(separator: "\n"))

        Write one concise \(kind.title.lowercased()) insight tailored to this summary.
        """
    }

    static func simulationPrompt(input: SimulationInput, projection: SimulationProjection) -> String {
        """
        Current monthly spending: \(CurrencyFormatter.pesoString(from: input.currentMonthlySpending))
        Daily savings target: \(CurrencyFormatter.pesoString(from: input.dailySavings))
        Spending reduction: \(PercentFormatter.string(from: input.reductionPercent / 100))
        Savings goal: \(CurrencyFormatter.pesoString(from: input.savingsGoal))
        Monthly savings result: \(CurrencyFormatter.pesoString(from: projection.monthlySavings))
        3-month projection: \(CurrencyFormatter.pesoString(from: projection.projectedSavingsThreeMonths))
        6-month projection: \(CurrencyFormatter.pesoString(from: projection.projectedSavingsSixMonths))
        12-month projection: \(CurrencyFormatter.pesoString(from: projection.projectedSavingsTwelveMonths))
        Months to goal: \(projection.monthsToGoal.map(String.init) ?? "Not available")

        Explain the tradeoff and suggest one realistic next step without changing the numbers.
        """
    }
}
