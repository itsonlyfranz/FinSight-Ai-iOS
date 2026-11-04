import Foundation

/// Rough token accounting for the on-device model's small context window.
enum TokenBudget {
    /// Tokens held back for the model's answer.
    static let responseReserve = 900
    /// Tokens held back for instructions, the output schema and the tool definitions.
    static let overheadReserve = 900
    /// Never plan for less than this, whatever the context size reports.
    static let minimumPromptTokens = 400

    /// Conservative estimate: one token per three UTF-8 bytes overshoots English (about four characters
    /// per token) and stays safe for non-Latin text, so a prompt that fits the estimate fits the model.
    static func estimate(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }

    /// Tokens the grounding prompt may use for a model with `contextSize` tokens of context.
    static func promptBudget(contextSize: Int) -> Int {
        max(minimumPromptTokens, contextSize - responseReserve - overheadReserve)
    }
}

/// The grounding prompt and what had to be left out to fit the token budget.
struct NarrationPrompt: Equatable, Sendable {
    let text: String
    let includedInsightIDs: [String]
    let omittedInsightCount: Int
    let historyMonths: Int
    let estimatedTokens: Int
}

/// Everything the model is told about the user's money, built from code.
///
/// The model gets the month's summary, the engine's typed insights (already ranked by severity and
/// impact) and a short month-by-month history, trimmed to a token budget. Anything it needs beyond
/// that it asks for through tools, which read the same `LedgerSnapshot`.
struct NarrationContext: Sendable {
    /// Complete months before the current one shown as history.
    static let historyMonths = 3
    /// Insights above this many are never sent, however much room is left.
    static let maximumInsights = 6
    static let topCategoriesPerMonth = 4

    let summary: MonthlySummary
    let insights: [Insight]
    let ledger: LedgerSnapshot

    func prompt(maxTokens: Int) -> NarrationPrompt {
        // Shrink the history first (it is the least specific), then the insight list.
        for months in stride(from: Self.historyMonths, through: 0, by: -1) {
            let header = Self.header(summary: summary, ledger: ledger, historyMonths: months)
            var text = header
            var included: [String] = []
            for insight in insights.prefix(Self.maximumInsights) {
                let candidate = text + "\n" + Self.line(for: insight)
                guard TokenBudget.estimate(candidate + Self.closing) <= maxTokens else { break }
                text = candidate
                included.append(insight.id)
            }
            let final = text + Self.closing
            let fits = TokenBudget.estimate(final) <= maxTokens
            // Accept this history size once it leaves room for at least the top insight (or there are none).
            if fits && (!included.isEmpty || insights.isEmpty || months == 0) {
                return NarrationPrompt(
                    text: final,
                    includedInsightIDs: included,
                    omittedInsightCount: insights.count - included.count,
                    historyMonths: months,
                    estimatedTokens: TokenBudget.estimate(final)
                )
            }
        }
        // The summary alone is over budget: send it uncut rather than nothing.
        let bare = Self.header(summary: summary, ledger: ledger, historyMonths: 0) + Self.closing
        return NarrationPrompt(
            text: bare,
            includedInsightIDs: [],
            omittedInsightCount: insights.count,
            historyMonths: 0,
            estimatedTokens: TokenBudget.estimate(bare)
        )
    }

    private static let closing = "\n\nWrite the budgeting, risk and growth narration from these facts. Call a tool for any figure that isn't listed."

    static func header(summary: MonthlySummary, ledger: LedgerSnapshot, historyMonths: Int) -> String {
        var lines = [
            "Currency: \(CurrencyFormatter.currencyCode)",
            "This month (\(summary.monthLabel)) so far: spent \(CurrencyFormatter.string(from: summary.totalSpent)) in \(summary.transactionCount) transactions; recurring \(CurrencyFormatter.string(from: summary.recurringMonthlySpend)), one-off \(CurrencyFormatter.string(from: summary.oneOffSpent)).",
            "Top category: \(summary.topCategory?.title ?? "none") (\(PercentFormatter.string(from: summary.topCategoryShare)) of spending).",
            "Trend: \(summary.spendingTrendDescription)"
        ]
        if historyMonths > 0 {
            lines.append("Previous months:")
            for offset in 1...historyMonths {
                let total = ledger.totalSpending(monthsAgo: offset)
                guard total > 0 else { continue }
                let top = ledger.categoryTotals(monthsAgo: offset)
                    .prefix(topCategoriesPerMonth)
                    .map { "\($0.category.title) \(LedgerText.money($0.total))" }
                    .joined(separator: ", ")
                lines.append("- \(LedgerText.monthLabel(ledger, monthsAgo: offset)): \(LedgerText.money(total)) (\(top))")
            }
        }
        lines.append("Insights found by the app, most important first:")
        return lines.joined(separator: "\n")
    }

    static func line(for insight: Insight) -> String {
        var line = "- [\(insight.severity.title)] \(insight.title): \(insight.summary) (\(LedgerText.money(insight.impactAmount)) \(insight.impactCaption))"
        if !insight.suggestedAction.isEmpty { line += " Suggested: \(insight.suggestedAction)" }
        return line
    }
}

/// One card of structured narration, before it becomes markdown.
struct NarrationCardContent: Equatable, Sendable {
    var takeaway: String
    var whyItMatters: String
    var nextSteps: [String]

    var isComplete: Bool {
        !takeaway.trimmed.isEmpty && !whyItMatters.trimmed.isEmpty && !nextSteps.filter { !$0.trimmed.isEmpty }.isEmpty
    }

    /// The markdown card the UI renders. Sections that haven't streamed in yet are left out.
    var markdown: String {
        var sections: [String] = []
        if !takeaway.trimmed.isEmpty { sections.append("## Key Takeaway\n\n\(takeaway.trimmed)") }
        if !whyItMatters.trimmed.isEmpty { sections.append("## Why It Matters\n\n\(whyItMatters.trimmed)") }
        let steps = nextSteps.map(\.trimmed).filter { !$0.isEmpty }
        if !steps.isEmpty { sections.append("## Next Step\n\n" + steps.map { "- \($0)" }.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
