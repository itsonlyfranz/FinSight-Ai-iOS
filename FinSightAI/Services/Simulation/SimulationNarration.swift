import Foundation

/// Everything the on-device model is told about a scenario: exact figures rendered by code, so the
/// model explains numbers rather than computing them, and every amount it quotes can be checked
/// against this text.
struct SimulationNarrationContext: Equatable, Sendable {
    let facts: String

    /// Identifies the data the explanation is generated from. A scenario with the same figures
    /// reuses the cached explanation; changing any figure regenerates it.
    var fingerprint: String { facts }
}

enum SimulationFacts {
    static func context(
        scenario rawScenario: SimulationScenario,
        baseline: RunRateBaseline,
        result: SimulationResult
    ) -> SimulationNarrationContext {
        let scenario = rawScenario.normalized
        var lines = [
            "Currency: \(CurrencyFormatter.currencyCode)",
            "Typical full month of spending: \(money(baseline.monthlyTotal)) "
                + "(everyday \(money(baseline.discretionaryTotal)), recurring charges \(money(baseline.recurringTotal))).",
            "Annual yield on savings: \(percent(scenario.annualYieldPercent))."
        ]
        if baseline.excludedOneOffTotal > 0 {
            lines.append("Left out of that as one-off purchases: \(money(baseline.excludedOneOffTotal)).")
        }
        if scenario.startingBalance > 0 {
            lines.append("Starting savings: \(money(scenario.startingBalance)).")
        }

        lines.append("Changes in this scenario:")
        for saving in result.categorySavings {
            lines.append("- Cut \(saving.category.title) by \(saving.percent)% of \(money(saving.monthlyBaseline)) a month: frees \(money(saving.saved)) a month.")
        }
        if result.dailySavingsPerMonth > 0 {
            lines.append("- Save \(money(scenario.dailySavings)) a day: \(money(result.dailySavingsPerMonth)) a month.")
        }
        if result.pausedRecurringSavings > 0 {
            lines.append("- Pause \(result.pausedRecurringNames.joined(separator: ", ")): frees \(money(result.pausedRecurringSavings)) a month.")
        }
        if !result.hasSavings {
            lines.append("- No changes yet.")
        }

        lines.append("Result: frees \(money(result.monthlySavings)) a month.")
        for point in result.milestones {
            var line = "After \(point.month) months: \(money(point.balance)) saved (\(money(point.contributed)) put in, \(money(point.interest)) interest)."
            if let lower = point.lower, let upper = point.upper, point.month == result.milestones.last?.month {
                line += " Likely range \(money(lower)) to \(money(upper))."
            }
            lines.append(line)
        }

        let goals = result.goals.filter { $0.status != .reached }
        if !goals.isEmpty {
            lines.append("Goals (each measured on its own):")
            lines.append(contentsOf: goals.map(goalLine))
        }
        return SimulationNarrationContext(facts: lines.joined(separator: "\n"))
    }

    static func goalLine(_ goal: GoalCountdown) -> String {
        var line = "- \(goal.name): \(money(goal.remaining)) to go; "
        switch goal.status {
        case .reached:
            line += "already funded."
        case .noPace:
            line += "no savings pace, so it isn't funded within 50 years."
        case .onTrack, .behind:
            let months = goal.planMonths ?? 0
            line += "funded in \(months) \(months == 1 ? "month" : "months") with this scenario"
            if let fundedBy = goal.fundedBy { line += " (by \(MonthFormatter.label(for: fundedBy)))" }
            if let sooner = goal.monthsSooner, sooner > 0 {
                line += ", \(sooner) \(sooner == 1 ? "month" : "months") sooner than now"
            }
            line += "."
            if goal.status == .behind, let targetDate = goal.targetDate {
                line += " That misses its target date of \(MonthFormatter.label(for: targetDate))."
            }
        }
        return line
    }

    static func money(_ value: Decimal) -> String { LedgerText.money(value) }

    static func percent(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }
}

/// One explanation, before it becomes markdown.
struct SimulationNarrationContent: Equatable, Sendable {
    var summary: String
    var tradeoff: String
    var nextSteps: [String]

    /// Markdown with the three sections the simulator's explanation card renders. Empty sections are
    /// skipped, so a partially streamed explanation renders cleanly.
    var markdown: String {
        var sections: [String] = []
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let tradeoff = tradeoff.trimmingCharacters(in: .whitespacesAndNewlines)
        let steps = nextSteps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !summary.isEmpty { sections.append("## Scenario Summary\n\n\(summary)") }
        if !tradeoff.isEmpty { sections.append("## Tradeoff\n\n\(tradeoff)") }
        if !steps.isEmpty { sections.append("## Recommended Next Step\n\n" + steps.map { "- \($0)" }.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }
}

/// The explanation written by code alone: shown whenever the on-device model is unavailable, fails,
/// or quotes figures the data doesn't support, so the simulator never depends on AI to make sense.
enum SimulationSummaryText {
    static func content(
        scenario rawScenario: SimulationScenario,
        result: SimulationResult
    ) -> SimulationNarrationContent {
        let scenario = rawScenario.normalized
        let money = SimulationFacts.money

        guard result.hasSavings else {
            return SimulationNarrationContent(
                summary: "Nothing is being saved yet. Cut a category, set a daily amount or pause a recurring charge to see what it adds up to.",
                tradeoff: "With no changes, spending stays at your typical month.",
                nextSteps: ["Start with your largest everyday category and try a small cut."]
            )
        }

        let twelve = result.point(atMonth: 12)
        var summary = "This plan frees \(money(result.monthlySavings)) a month."
        if let twelve {
            summary += " After 12 months that grows to \(money(twelve.balance)), "
                + "including \(money(twelve.interest)) of interest at \(SimulationFacts.percent(scenario.annualYieldPercent)) a year."
        }

        var tradeoff = result.categorySavings.isEmpty
            ? "The savings come from setting money aside rather than cutting a category."
            : "You would spend less on "
                + result.categorySavings.map { "\($0.category.title) (\($0.percent)% less)" }.joined(separator: ", ") + "."
        if let twelve, let lower = twelve.lower, let upper = twelve.upper {
            tradeoff += " Spending varies month to month, so the 12-month balance could land between \(money(lower)) and \(money(upper))."
        }

        var steps: [String] = []
        if let biggest = result.categorySavings.first {
            steps.append("Start with \(biggest.category.title): it frees the most, \(money(biggest.saved)) a month.")
        }
        if let goal = result.goals.first(where: { $0.status == .onTrack || $0.status == .behind }), let fundedBy = goal.fundedBy {
            steps.append("At this pace \(goal.name) is funded by \(MonthFormatter.label(for: fundedBy)).")
        }
        if steps.isEmpty { steps.append("Move the savings into a separate account so it is not spent.") }
        return SimulationNarrationContent(summary: summary, tradeoff: tradeoff, nextSteps: Array(steps.prefix(2)))
    }
}
