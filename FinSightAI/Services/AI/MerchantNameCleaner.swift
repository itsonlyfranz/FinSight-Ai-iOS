import Foundation

/// Turns raw bank-style merchant text ("SQ *BLUE BOTTLE COFFEE #1234", "AMZN Mktp US*2K4") into the
/// name a person would write ("Blue Bottle Coffee", "Amazon"). Deterministic, idempotent and
/// conservative: text that already looks hand-written comes back unchanged.
enum MerchantNameCleaner {
    /// Payment-processor and card-terminal prefixes that are never part of the merchant's name.
    private static let prefixes = [
        "sq *", "sq*", "tst*", "tst *", "paypal *", "paypal*", "pp*", "pos debit", "pos purchase", "pos ",
        "debit card purchase", "card purchase", "purchase", "checkcard", "visa purchase"
    ]

    /// Well-known descriptors and the name they stand for. Matched on the start of the cleaned text.
    private static let aliases: [(prefix: String, name: String)] = [
        ("amzn mktp", "Amazon"), ("amzn", "Amazon"), ("amazon", "Amazon"),
        ("wal-mart", "Walmart"), ("walmart", "Walmart"), ("wm supercenter", "Walmart"),
        ("mcdonald", "McDonald's"), ("starbucks", "Starbucks"), ("netflix", "Netflix"),
        ("spotify", "Spotify"), ("apple.com/bill", "Apple"), ("uber eats", "Uber Eats"),
        ("uber *eats", "Uber Eats"), ("uber", "Uber"), ("lyft", "Lyft"), ("doordash", "DoorDash"),
        ("trader joe", "Trader Joe's"), ("whole foods", "Whole Foods"), ("7-eleven", "7-Eleven")
    ]

    private static let companySuffixes: Set<String> = ["inc", "inc.", "llc", "ltd", "ltd.", "corp", "corp.", "co.", "gmbh"]

    static func clean(_ raw: String) -> String {
        var text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "" }
        let original = text

        text = strippingPrefixes(text)
        text = strippingTrailingNoise(text)

        let lowered = text.lowercased()
        if let alias = aliases.first(where: { lowered.hasPrefix($0.prefix) }) {
            return alias.name
        }
        if text.isEmpty { return original }
        return looksUnformatted(text) ? titleCased(text) : text
    }

    private static func strippingPrefixes(_ text: String) -> String {
        var text = text
        var changed = true
        while changed {
            changed = false
            let lowered = text.lowercased()
            if let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return text
    }

    /// Drops store numbers, terminal ids, `*REF` suffixes and legal suffixes from the end.
    private static func strippingTrailingNoise(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        // "AMZN Mktp US*2K4HG" → everything after a `*` reference is noise.
        if let last = words.last, let star = last.firstIndex(of: "*"), star != last.startIndex {
            words[words.count - 1] = String(last[..<star])
        }
        while let last = words.last {
            let lowered = last.lowercased()
            let isStoreNumber = lowered.hasPrefix("#") || (lowered.count >= 3 && lowered.allSatisfy(\.isNumber))
            let isMaskedCard = lowered.hasPrefix("xxxx") || lowered.hasPrefix("****")
            let isNumberLabel = ["no", "no.", "store"].contains(lowered) && words.count > 1
            if last.isEmpty || isStoreNumber || isMaskedCard || isNumberLabel || companySuffixes.contains(lowered) {
                words.removeLast()
            } else {
                break
            }
        }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " *-,."))
    }

    /// All caps or all lowercase reads as raw text; mixed case was probably typed on purpose.
    private static func looksUnformatted(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        return letters.allSatisfy(\.isUppercase) || letters.allSatisfy(\.isLowercase)
    }

    private static let acronyms: Set<String> = ["bp", "kfc", "cvs", "hbo", "atm", "ups", "tfl", "usps", "ikea"]

    private static func titleCased(_ text: String) -> String {
        text.split(separator: " ").map { word in
            let word = String(word)
            if acronyms.contains(word.lowercased()) { return word.uppercased() }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
