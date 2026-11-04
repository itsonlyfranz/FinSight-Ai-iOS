import Foundation

/// What a quick-add sentence ("coffee 150 yesterday") turned into.
///
/// The amount and the date are always read by `QuickAddParser`, never by the model, so the numbers
/// in a draft are exactly what the user typed. The model may only improve the wording: the merchant
/// name, the category and the income/expense call.
struct QuickAddResult: Equatable, Sendable {
    var amount: Decimal?
    var kind: TransactionKind
    var merchant: String
    /// The category and whether a keyword rule or the model chose it.
    var category: CategorySuggestion?
    var date: Date
    /// The sentence with the amount and date phrases removed, which is what the model is shown.
    var remainder: String

    /// Enough to save: a positive amount and a name.
    var isComplete: Bool {
        guard let amount, amount > 0 else { return false }
        return !merchant.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

extension TransactionDraft {
    /// Fills a draft from a parsed sentence. `category` falls back to `.other` when nothing matched,
    /// so a draft never silently claims a category nobody chose.
    init(quickAdd result: QuickAddResult, locale: Locale = .current) {
        self.init()
        self.locale = locale
        amountText = result.amount.map { CurrencyFormatter.plainNumberString(from: $0, locale: locale) } ?? ""
        kind = result.kind
        merchantName = result.merchant
        category = result.category?.category ?? .other
        date = result.date
    }
}

/// Reads amount, date and kind out of a short sentence, entirely in code. Understands "today",
/// "yesterday", "N days/weeks ago", weekday names ("on monday", "last friday") and ISO dates.
enum QuickAddParser {
    static func parse(
        _ text: String,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> QuickAddResult {
        var remaining = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lowered = remaining.lowercased()

        let kind = kind(in: lowered)
        let (date, afterDate) = extractDate(from: remaining, now: now, calendar: calendar)
        remaining = afterDate
        let (amount, afterAmount) = extractAmount(from: remaining, locale: locale)
        remaining = afterAmount

        let remainder = cleaned(remaining)
        let merchant = MerchantNameCleaner.clean(strippedOfFiller(remainder))
        let category = kind == .income ? nil : KeywordCategorizer.category(for: [merchant, text]).map {
            CategorySuggestion(category: $0, source: .rule)
        }
        return QuickAddResult(
            amount: amount,
            kind: kind,
            merchant: merchant,
            category: category,
            date: date,
            remainder: remainder
        )
    }

    // MARK: - Kind

    private static let incomeWords = ["salary", "paycheck", "paycheque", "payday", "income", "wages", "got paid", "bonus", "freelance"]

    private static func kind(in lowered: String) -> TransactionKind {
        let padded = " \(lowered) "
        if padded.contains(" transfer ") || padded.contains(" transferred ") { return .transfer }
        if incomeWords.contains(where: { padded.contains(" \($0) ") }) { return .income }
        return .expense
    }

    // MARK: - Date

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func extractDate(from text: String, now: Date, calendar: Calendar) -> (Date, String) {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: today) ?? today }

        // Ordered most to least specific so "day before yesterday" isn't read as "yesterday".
        if let range = text.range(of: #"\b(\d{4})-(\d{2})-(\d{2})\b"#, options: .regularExpression) {
            let parts = text[range].split(separator: "-").compactMap { Int($0) }
            if parts.count == 3,
               let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
               date <= today {
                return (date, removing(range, from: text))
            }
        }
        if let range = text.range(of: #"\bday before yesterday\b"#, options: [.regularExpression, .caseInsensitive]) {
            return (day(2), removing(range, from: text))
        }
        if let range = text.range(of: #"\byesterday\b"#, options: [.regularExpression, .caseInsensitive]) {
            return (day(1), removing(range, from: text))
        }
        if let range = text.range(of: #"\btoday\b"#, options: [.regularExpression, .caseInsensitive]) {
            return (today, removing(range, from: text))
        }
        if let range = text.range(of: #"\b(\d{1,3})\s*(day|days|week|weeks)\s+ago\b"#, options: [.regularExpression, .caseInsensitive]) {
            let phrase = text[range].lowercased()
            let number = Int(phrase.prefix { $0.isNumber }) ?? 0
            let offset = phrase.contains("week") ? number * 7 : number
            return (day(offset), removing(range, from: text))
        }
        if let range = text.range(of: #"\blast week\b"#, options: [.regularExpression, .caseInsensitive]) {
            return (day(7), removing(range, from: text))
        }
        for (index, name) in weekdays.enumerated() {
            let pattern = #"\b(?:(last|on)\s+)?"# + name + #"\b"#
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            let isLast = text[range].lowercased().hasPrefix("last")
            let todayIndex = calendar.component(.weekday, from: today) - 1
            var back = (todayIndex - index + 7) % 7
            // "last monday" on a Monday is a week ago; a bare "monday" on a Monday is today.
            if back == 0 && isLast { back = 7 }
            return (day(back), removing(range, from: text))
        }
        return (today, text)
    }

    private static func removing(_ range: Range<String.Index>, from text: String) -> String {
        var copy = text
        copy.removeSubrange(range)
        return copy
    }

    // MARK: - Amount

    private static func extractAmount(from text: String, locale: Locale) -> (Decimal?, String) {
        // A number counts only when it isn't a store number ("#44") or part of a name ("7-Eleven", "A1").
        let pattern = #"(?<![\w#])(?:[$€£¥]\s*)?\d[\d.,]*(?![\w-]*[A-Za-z])(?:\s*(?:usd|eur|gbp|dollars?|euros?|bucks))?|[$€£¥]\s*\d[\d.,]*"#
        let matches = text.ranges(of: pattern, options: [.regularExpression, .caseInsensitive])
        // Prefer a number carrying a currency symbol or word, else the last one ("2 coffees 8.50").
        let preferred = matches.first { range in
            let token = text[range]
            return token.contains(where: { "$€£¥".contains($0) }) || token.lowercased().contains(where: \.isLetter)
        } ?? matches.last
        guard let range = preferred else { return (nil, text) }

        let digits = String(text[range])
            .filter { $0.isNumber || $0 == "." || $0 == "," }
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        let value = AmountParser.parse(digits, locale: locale)
            ?? AmountParser.parse(digits, locale: Locale(identifier: "en_US_POSIX"))
        return (value.flatMap { $0 > 0 ? $0 : nil }, removing(range, from: text))
    }

    // MARK: - Wording

    private static let filler: Set<String> = [
        "spent", "paid", "pay", "bought", "buy", "for", "at", "on", "in", "from", "to", "a", "an", "the", "of",
        "got", "received", "my", "with", "using", "usd", "eur", "gbp", "dollars", "euros", "bucks", "expense", "i"
    ]

    private static func cleaned(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
    }

    private static func strippedOfFiller(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let first = words.first, filler.contains(first.lowercased()) { words.removeFirst() }
        while let last = words.last, filler.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator: " ")
    }
}

private extension String {
    func ranges(of pattern: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex, let range = range(of: pattern, options: options, range: cursor..<endIndex) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}
