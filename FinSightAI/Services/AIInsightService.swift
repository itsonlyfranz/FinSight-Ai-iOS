import Foundation

protocol AIInsightService {
    func generateInsights(from summary: MonthlySummary) async throws -> [InsightCard]
    func explainSimulation(input: SimulationInput, projection: SimulationProjection) async throws -> String
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

    func generateInsights(from summary: MonthlySummary) async throws -> [InsightCard] {
        throw AIInsightError.unavailable(reason)
    }

    func explainSimulation(input: SimulationInput, projection: SimulationProjection) async throws -> String {
        throw AIInsightError.unavailable(reason)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
struct AppleFoundationModelsInsightService: AIInsightService {
    func generateInsights(from summary: MonthlySummary) async throws -> [InsightCard] {
        var cards: [InsightCard] = []

        for kind in InsightKind.allCases {
            let prompt = PromptFactory.insightPrompt(for: kind, summary: summary)
            let session = LanguageModelSession(instructions: PromptFactory.instructions(for: kind))
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AIInsightError.emptyResponse }
            cards.append(InsightCard(kind: kind, body: text))
        }

        return cards
    }

    func explainSimulation(input: SimulationInput, projection: SimulationProjection) async throws -> String {
        let session = LanguageModelSession(instructions: PromptFactory.simulationInstructions)
        let response = try await session.respond(to: PromptFactory.simulationPrompt(input: input, projection: projection))
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIInsightError.emptyResponse }
        return text
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
            """
        case .risk:
            """
            You are a financial risk analyst.
            Review monthly spending summaries for risk signals such as rising expenses, weak savings behavior, or concentration in volatile categories.
            Be direct but constructive. Do not provide regulated financial advice.
            """
        case .growth:
            """
            You are a financial growth coach.
            Suggest realistic improvements that help the user save more or redirect spending more effectively.
            Keep the response actionable, concise, and grounded in the supplied summary.
            """
        }
    }

    static var simulationInstructions: String {
        """
        You explain savings simulations in plain language.
        Use the supplied numeric projection as the source of truth and do not change the numbers.
        Keep the response concise, practical, and educational.
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
