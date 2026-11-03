import Foundation

/// Checks that every amount in generated text came from code.
///
/// The model is told to quote only listed or tool-returned amounts, but a small model still
/// sometimes subtracts, rounds or invents one ("$180 saved" when $180 was the spend). Any amount in
/// the narration that appears nowhere in the facts or tool results is treated as a hallucination.
enum FigureGrounding {
    /// Amounts in `text`: numbers written next to a currency symbol or a three-letter currency code.
    static func amounts(in text: String) -> [Decimal] {
        tokens(in: text).filter(\.isCurrency).map(\.value)
    }

    /// Every number in `text`, currency or not, rounded to cents.
    static func numbers(in text: String) -> Set<Decimal> {
        Set(tokens(in: text).map(\.value))
    }

    /// Amounts in `narration` that aren't a number in any of `sources`, in order of appearance.
    static func ungroundedAmounts(in narration: String, sources: [String]) -> [Decimal] {
        let known = sources.reduce(into: Set<Decimal>()) { $0.formUnion(numbers(in: $1)) }
        var seen = Set<Decimal>()
        return amounts(in: narration).filter { !known.contains($0) && seen.insert($0).inserted }
    }

    // MARK: - Tokenising

    private struct Token {
        let value: Decimal
        let isCurrency: Bool
    }

    private static func tokens(in text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isASCII, characters[index].isNumber else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count,
                  (characters[end].isASCII && characters[end].isNumber)
                    || ((characters[end] == "," || characters[end] == ".")
                        && end + 1 < characters.count && characters[end + 1].isASCII && characters[end + 1].isNumber) {
                end += 1
            }
            let raw = String(characters[index..<end])
            let isCurrency = hasCurrencyBefore(characters, index) || hasCurrencyAfter(characters, end)
            if let value = parse(raw) { tokens.append(Token(value: value, isCurrency: isCurrency)) }
            index = end
        }
        return tokens
    }

    /// "1,070.00", "1.070,00", "12,50", "1070" → 1070, 1070, 12.5, 1070 (rounded to cents).
    static func parse(_ raw: String) -> Decimal? {
        let lastComma = raw.lastIndex(of: ",")
        let lastDot = raw.lastIndex(of: ".")
        var integer = raw
        var fraction = ""
        let decimalIndex: String.Index?
        switch (lastComma, lastDot) {
        case let (comma?, dot?): decimalIndex = max(comma, dot)
        case let (comma?, nil): decimalIndex = isDecimalSeparator(raw, at: comma) ? comma : nil
        case let (nil, dot?): decimalIndex = isDecimalSeparator(raw, at: dot) ? dot : nil
        case (nil, nil): decimalIndex = nil
        }
        if let decimalIndex {
            integer = String(raw[..<decimalIndex])
            fraction = String(raw[raw.index(after: decimalIndex)...])
        }
        let digits = integer.filter(\.isNumber) + (fraction.isEmpty ? "" : "." + fraction)
        guard let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return value.rounded(scale: 2)
    }

    /// A lone separator is decimal unless it groups exactly three digits ("1,070") or repeats ("1,070,000").
    private static func isDecimalSeparator(_ raw: String, at index: String.Index) -> Bool {
        let separator = raw[index]
        let after = raw[raw.index(after: index)...]
        if raw.filter({ $0 == separator }).count > 1 { return false }
        return after.count != 3
    }

    private static func hasCurrencyBefore(_ characters: [Character], _ index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == " " || characters[cursor] == "\u{00A0}" || characters[cursor] == "-" { cursor -= 1 }
        guard cursor >= 0 else { return false }
        return isCurrencySymbol(characters[cursor]) || endsWithCode(characters, upTo: cursor)
    }

    private static func hasCurrencyAfter(_ characters: [Character], _ index: Int) -> Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\u{00A0}" { cursor += 1 }
        guard cursor < characters.count else { return false }
        return isCurrencySymbol(characters[cursor]) || startsWithCode(characters, from: cursor)
    }

    private static func isCurrencySymbol(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.generalCategory == .currencySymbol }
    }

    /// Three upper-case letters ending at `cursor`, not part of a longer word ("USD", not "MUSD").
    private static func endsWithCode(_ characters: [Character], upTo cursor: Int) -> Bool {
        guard cursor >= 2 else { return false }
        let code = characters[(cursor - 2)...cursor]
        guard code.allSatisfy({ $0.isUppercase && $0.isASCII }) else { return false }
        return cursor - 3 < 0 || !characters[cursor - 3].isLetter
    }

    private static func startsWithCode(_ characters: [Character], from cursor: Int) -> Bool {
        guard cursor + 2 < characters.count else { return false }
        let code = characters[cursor...(cursor + 2)]
        guard code.allSatisfy({ $0.isUppercase && $0.isASCII }) else { return false }
        return cursor + 3 >= characters.count || !characters[cursor + 3].isLetter
    }
}

/// Collects what tools returned during a session, so the figures in them count as grounded.
final class ToolOutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ output: String) { lock.withLock { entries.append(output) } }
    var outputs: [String] { lock.withLock { entries } }
}
