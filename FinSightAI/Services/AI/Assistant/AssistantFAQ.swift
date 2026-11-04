import Foundation

/// What a question is about, as far as simple rules can tell.
enum AssistantIntent: Equatable, Sendable {
    /// "Can I afford 8k this month?"
    case affordability(Decimal)
    /// "Can I afford it?" with no amount to check.
    case affordabilityWithoutAmount
    /// "Why was March so high?" — a month by how many months ago it was (0 = this month).
    case monthReview(monthsAgo: Int)
    /// "How much have I spent this month?"
    case spending
    /// "Where is most of my money going?"
    case topCategories
    case budgets
    case recurring
    case goals
    /// "How can I save more?" — the engine's insights.
    case watchOuts
    case greeting
    /// Nothing recognised: list what the assistant can answer.
    case help
}

/// The deterministic "quick answers" behind Ask FinSight: rules pick the question type, code works
/// out the answer from the user's data. Used on devices without Apple Intelligence and whenever the
/// on-device model can't answer, so the chat always replies with real numbers.
enum AssistantFAQ {
    // MARK: Matching

    static func intent(for question: String, now: Date, calendar: Calendar) -> AssistantIntent {
        let text = normalized(question)
        if contains(text, Keywords.afford) {
            return AssistantAmountParser.amount(in: question).map(AssistantIntent.affordability) ?? .affordabilityWithoutAmount
        }
        if let monthsAgo = AssistantMonthResolver.monthsAgo(in: question, now: now, calendar: calendar),
           monthsAgo > 0 || contains(text, Keywords.why) {
            return .monthReview(monthsAgo: monthsAgo)
        }
        if contains(text, Keywords.why) && contains(text, Keywords.high) { return .monthReview(monthsAgo: 0) }
        if contains(text, Keywords.budget) { return .budgets }
        if contains(text, Keywords.recurring) { return .recurring }
        if contains(text, Keywords.goal) { return .goals }
        if contains(text, Keywords.topCategory) { return .topCategories }
        if contains(text, Keywords.spending) { return .spending }
        if contains(text, Keywords.watchOut) { return .watchOuts }
        if contains(text, Keywords.greeting) { return .greeting }
        return .help
    }

    // MARK: Answers

    static func answer(to question: String, context: AssistantContext) -> String {
        answer(for: intent(for: question, now: context.now, calendar: context.calendar), context: context)
    }

    static func answer(for intent: AssistantIntent, context: AssistantContext) -> String {
        switch intent {
        case .greeting: return greeting(context)
        case .help: return help(context)
        case .affordabilityWithoutAmount:
            return String(localized: "Tell me the amount and I'll check it against what's left this month, for example: \"Can I afford \(AssistantSuggestions.exampleAmountText) this month?\"")
        default: break
        }
        guard context.hasData else {
            return String(localized: "I don't have any transactions to look at yet. Add a few expenses, or load sample data in Settings, and ask me again.")
        }
        switch intent {
        case .affordability(let amount): return affordability(AffordabilityCheck.make(amount: amount, context: context), context: context)
        case .monthReview(let monthsAgo): return monthReview(MonthReview.make(monthsAgo: monthsAgo, ledger: context.ledger))
        case .spending: return spending(context)
        case .topCategories: return topCategories(context)
        case .budgets: return budgets(context)
        case .recurring: return recurring(context)
        case .goals: return goals(context)
        case .watchOuts: return watchOuts(context)
        case .greeting, .help, .affordabilityWithoutAmount: return help(context)
        }
    }

    private static func money(_ value: Decimal) -> String { CurrencyFormatter.string(from: value) }

    private static func greeting(_ context: AssistantContext) -> String {
        let hello = context.profile.name.isEmpty
            ? String(localized: "Hi! I'm FinSight AI, your money coach.")
            : String(localized: "Hi \(context.profile.name)! I'm FinSight AI, your money coach.")
        return hello + " " + String(localized: "Ask me about your spending, budgets, savings goals or recurring charges.")
    }

    private static func help(_ context: AssistantContext) -> String {
        let prompts = AssistantSuggestions.prompts(for: context).map { "- \($0)" }.joined(separator: "\n")
        return String(localized: "I can answer questions about your spending, budgets, savings goals and recurring charges. Try one of these:") + "\n\n" + prompts
    }

    private static func spending(_ context: AssistantContext) -> String {
        let spent = context.ledger.totalSpending(monthsAgo: 0)
        var parts = [String(localized: "So far this month you've spent \(money(spent)).")]
        if let top = context.ledger.categoryTotals(monthsAgo: 0).first, spent > 0 {
            let share = PercentFormatter.string(from: (top.total / spent).doubleValue)
            parts.append(String(localized: "Your biggest category is \(top.category.localizedTitle) at \(money(top.total)) (\(share) of spending)."))
        }
        parts.append(String(localized: context.summary.spendingTrend))
        let lastMonth = context.ledger.totalSpending(monthsAgo: 1)
        if lastMonth > 0 {
            parts.append(String(localized: "Last month you spent \(money(lastMonth)) in total."))
        }
        return parts.joined(separator: " ")
    }

    private static func topCategories(_ context: AssistantContext) -> String {
        let totals = context.ledger.categoryTotals(monthsAgo: 0)
        guard !totals.isEmpty else {
            return String(localized: "You haven't logged any spending this month yet.")
        }
        let total = totals.map(\.total).sum()
        let lines = totals.prefix(3).map { line in
            "- \(line.category.localizedTitle): \(money(line.total)) (\(PercentFormatter.string(from: (line.total / total).doubleValue)))"
        }
        return String(localized: "This month most of your money is going to:") + "\n" + lines.joined(separator: "\n")
    }

    private static func monthReview(_ review: MonthReview) -> String {
        let label = MonthFormatter.label(for: review.monthStart)
        let previousLabel = MonthFormatter.label(for: review.previousMonthStart)
        guard review.total > 0 else {
            return String(localized: "I don't see any spending in \(label).")
        }
        var parts: [String] = []
        if review.previousTotal <= 0 {
            parts.append(String(localized: "In \(label) you spent \(money(review.total)). There's no spending logged in \(previousLabel) to compare it with."))
        } else if review.change > 0 {
            parts.append(String(localized: "In \(label) you spent \(money(review.total)), \(money(review.change)) more than in \(previousLabel) (\(money(review.previousTotal)))."))
        } else if review.change < 0 {
            parts.append(String(localized: "In \(label) you spent \(money(review.total)), \(money(-review.change)) less than in \(previousLabel) (\(money(review.previousTotal)))."))
        } else {
            parts.append(String(localized: "In \(label) you spent \(money(review.total)), the same as in \(previousLabel)."))
        }
        let increases = review.increases.prefix(MonthReview.maximumChanges)
        if review.previousTotal > 0, !increases.isEmpty {
            parts.append(String(localized: "The biggest increases:") + "\n" + increases.map {
                "- \($0.category.localizedTitle): " + ($0.previous > 0
                    ? String(localized: "up \(money($0.change)) to \(money($0.total))")
                    : String(localized: "\(money($0.total)), none the month before"))
            }.joined(separator: "\n"))
        }
        if !review.largestPurchases.isEmpty {
            parts.append(String(localized: "Largest purchases:") + "\n" + review.largestPurchases.map {
                "- \($0.merchant.isEmpty ? $0.category.localizedTitle : $0.merchant): \(money($0.amount))"
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func affordability(_ check: AffordabilityCheck, context: AssistantContext) -> String {
        let amount = money(check.amount)
        guard check.verdict != .noIncome else {
            return String(localized: "Add your monthly income in Settings and I can tell you whether \(amount) fits this month. So far this month you've spent \(money(check.spent)).")
        }
        var parts = [check.upcomingRecurring > 0
            ? String(localized: "This month's income is \(money(check.income)). You've spent \(money(check.spent)) so far and \(money(check.upcomingRecurring)) in recurring charges is still due, which leaves \(money(check.leftBefore)).")
            : String(localized: "This month's income is \(money(check.income)). You've spent \(money(check.spent)) so far, which leaves \(money(check.leftBefore)).")]
        switch check.verdict {
        case .comfortable:
            parts.append(String(localized: "Yes, \(amount) fits: you'd still have \(money(check.leftAfter)) for the rest of the month."))
        case .tight:
            parts.append(String(localized: "It fits, but only just: you'd have \(money(check.leftAfter)) left for the rest of the month."))
        case .short:
            parts.append(String(localized: "Not this month: \(amount) is \(money(check.shortfall)) more than you have left."))
            if let top = context.ledger.categoryTotals(monthsAgo: 0).first(where: { $0.category != .bills }) {
                parts.append(String(localized: "Consider waiting until next month, or cutting back on \(top.category.localizedTitle) (\(money(top.total)) so far)."))
            }
        case .noIncome:
            break
        }
        return parts.joined(separator: " ")
    }

    private static func budgets(_ context: AssistantContext) -> String {
        let lines = context.ledger.budgetStatus()
        guard !lines.isEmpty else {
            return String(localized: "You haven't set any budgets yet. Add them in Settings to track each category.")
        }
        let over = lines.filter(\.isOver).count
        let headline = over == 0
            ? String(localized: "You're within every budget this month.")
            : String(localized: "Categories over budget this month: \(over) of \(lines.count).")
        let rendered = lines.map { line in
            let state = line.isOver
                ? String(localized: "over by \(money(-line.remaining))")
                : String(localized: "\(money(line.remaining)) left")
            return "- \(line.category.localizedTitle): " + String(localized: "\(money(line.spent)) of \(money(line.limit)) (\(state))")
        }
        return headline + "\n" + rendered.joined(separator: "\n")
    }

    private static func recurring(_ context: AssistantContext) -> String {
        let charges = context.recurringCharges
        guard !charges.isEmpty else {
            let detected = context.insights.first { $0.kind == .recurringCharges }
            if let detected {
                return String(localized: "You haven't set up recurring charges, but I spotted some repeats in your spending:") + "\n- \(detected.title): \(detected.summary)"
            }
            return String(localized: "I don't see any recurring charges yet. Add them on the Transactions tab, or keep logging and I'll spot repeats.")
        }
        let total = charges.map(\.monthlyAmount).sum()
        let lines = charges.map { "- \($0.merchant): " + String(localized: "\(money($0.monthlyAmount)) a month") }
        return String(localized: "Your recurring charges add up to \(money(total)) a month:") + "\n" + lines.joined(separator: "\n")
    }

    private static func goals(_ context: AssistantContext) -> String {
        guard !context.goals.isEmpty else {
            return String(localized: "You haven't set a savings goal yet. Add one in Settings to track your progress.")
        }
        let lines = context.goals.map { goal in
            "- \(goal.name): " + String(localized: "\(money(goal.saved)) of \(money(goal.target)) (\(PercentFormatter.string(from: goal.fractionSaved)))")
        }
        return String(localized: "Here's how your savings goals are doing:") + "\n" + lines.joined(separator: "\n")
    }

    private static func watchOuts(_ context: AssistantContext) -> String {
        let top = context.insights.prefix(3)
        guard !top.isEmpty else {
            return String(localized: "Nothing stands out right now. Keep logging expenses and I'll flag budget, trend and subscription changes.")
        }
        let lines = top.map { insight in
            var line = "- **\(insight.title)**: \(insight.summary)"
            if !insight.suggestedAction.isEmpty { line += " " + insight.suggestedAction }
            return line
        }
        return String(localized: "Here's what stands out in your money right now:") + "\n" + lines.joined(separator: "\n")
    }

    // MARK: Text helpers

    static func normalized(_ text: String) -> String {
        " " + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ") + " "
    }

    /// Whether `text` (already `normalized`) contains any of `phrases` as whole words.
    static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains(" \($0) ") }
    }

    /// English and Filipino (including common Taglish) words for each kind of question.
    enum Keywords {
        static let afford = ["afford", "can i buy", "can i spend", "is it ok to spend", "should i buy", "kaya ko", "kaya ba", "kakayanin", "kasya", "pwede ko bang bilhin", "puwede ko bang bilhin"]
        static let why = ["why", "bakit"]
        static let high = ["high", "so high", "so much", "expensive", "mataas", "malaki", "ang laki"]
        static let budget = ["budget", "budgets", "badyet", "over budget", "on track", "limit", "limits"]
        static let recurring = ["subscription", "subscriptions", "recurring", "bills", "bill", "netflix", "spotify", "bayarin", "buwanang bayad"]
        static let goal = ["goal", "goals", "emergency fund", "target", "layunin", "ipon ko", "pinag iipunan"]
        static let topCategory = ["where", "most", "biggest", "category", "categories", "going", "saan", "napupunta", "pinakamalaki"]
        static let spending = ["spent", "spend", "spending", "how much", "total", "outflow", "gastos", "nagastos", "ginastos", "magkano"]
        static let watchOut = ["save", "saving", "savings", "tip", "tips", "advice", "watch", "risk", "risks", "insight", "insights", "improve", "cut", "cut back", "mag ipon", "makaipon", "makakaipon", "mag iipon", "ipon", "payo", "tipid", "magtipid"]
        static let greeting = ["hi", "hello", "hey", "help", "kumusta", "kamusta", "musta", "tulong"]
    }
}

/// The suggested prompts shown in the chat.
enum AssistantSuggestions {
    /// The affordability example uses this amount, as in "Can I afford 8k this month?".
    static let exampleAmount: Decimal = 8_000

    static func prompts(for context: AssistantContext) -> [String] {
        var prompts: [String] = []
        if let month = highestRecentMonth(in: context.ledger) {
            prompts.append(String(localized: "Why was \(monthName(month)) so high?"))
        } else {
            prompts.append(String(localized: "How much have I spent this month?"))
        }
        prompts.append(String(localized: "Can I afford \(exampleAmountText) this month?"))
        prompts.append(String(localized: "Where is most of my money going?"))
        prompts.append(String(localized: "Am I on track with my budgets?"))
        prompts.append(String(localized: "What subscriptions am I paying for?"))
        prompts.append(String(localized: "How can I save more this month?"))
        return prompts
    }

    /// The example amount without cents ("₱8,000"), as a person would type it.
    static var exampleAmountText: String {
        exampleAmount.formatted(.currency(code: CurrencyFormatter.currencyCode).precision(.fractionLength(0)))
    }

    /// The highest-spending complete month among the last six, if any month had spending.
    static func highestRecentMonth(in ledger: LedgerSnapshot) -> Date? {
        let candidates = (1...6).map { (ledger.monthStart(monthsAgo: $0), ledger.totalSpending(monthsAgo: $0)) }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    /// The month's stand-alone name in the user's language ("March", "Marso").
    static func monthName(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide))
    }
}

/// Reads an amount from a question: "8k", "₱8,000", "8.5k", "8000 pesos", "8 thousand", "8 libo".
enum AssistantAmountParser {
    static func amount(in text: String) -> Decimal? {
        let pattern = #"(\d[\d,\.]*)\s*(k|thousand|libo)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var fallback: Decimal?
        for match in regex.matches(in: text, range: range) {
            guard let numberRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[numberRange]).trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            guard var value = FigureGrounding.parse(raw), value > 0 else { continue }
            let hasMultiplier = match.range(at: 2).location != NSNotFound
            if hasMultiplier { value *= 1_000 }
            // A bare four-digit year next to a month ("March 2026") is not an amount.
            let looksLikeYear = !hasMultiplier && raw.count == 4 && raw.allSatisfy(\.isNumber) && (1900...2100).contains(Int(raw) ?? 0)
            if looksLikeYear {
                fallback = fallback ?? value
                continue
            }
            return value
        }
        return fallback
    }
}

/// Finds a month named in a question and how many months ago its latest occurrence was.
enum AssistantMonthResolver {
    /// Month names by month number, English and Filipino. English "May" is handled separately
    /// because "may" is also an everyday Filipino word ("there is").
    private static let names: [Int: [String]] = [
        1: ["january", "jan", "enero"],
        2: ["february", "feb", "pebrero", "febrero"],
        3: ["march", "mar", "marso"],
        4: ["april", "apr", "abril"],
        5: ["mayo"],
        6: ["june", "jun", "hunyo"],
        7: ["july", "jul", "hulyo"],
        8: ["august", "aug", "agosto"],
        9: ["september", "sep", "sept", "setyembre"],
        10: ["october", "oct", "oktubre"],
        11: ["november", "nov", "nobyembre"],
        12: ["december", "dec", "disyembre"]
    ]
    private static let mayPhrases = ["in may", "of may", "during may", "for may", "last may", "noong may", "nung may", "this may"]
    private static let lastMonth = ["last month", "previous month", "nakaraang buwan", "noong isang buwan", "nung isang buwan", "last buwan"]
    private static let thisMonth = ["this month", "ngayong buwan", "this buwan"]

    static func monthsAgo(in question: String, now: Date, calendar: Calendar) -> Int? {
        let text = AssistantFAQ.normalized(question)
        if AssistantFAQ.contains(text, lastMonth) { return 1 }
        if AssistantFAQ.contains(text, thisMonth) { return 0 }
        var month: Int?
        for (number, words) in names where AssistantFAQ.contains(text, words) {
            month = number
            break
        }
        if month == nil, AssistantFAQ.contains(text, mayPhrases) || text.range(of: #" may (19|20)\d\d "#, options: .regularExpression) != nil {
            month = 5
        }
        guard let month else { return nil }
        let current = calendar.component(.month, from: now)
        return (current - month + 12) % 12
    }
}
