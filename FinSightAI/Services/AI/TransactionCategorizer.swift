import Foundation

/// A category chosen for a transaction, and how it was chosen.
struct CategorySuggestion: Equatable, Sendable {
    enum Source: String, Sendable {
        /// A keyword rule matched.
        case rule
        /// The on-device model picked it.
        case model
    }

    let category: SpendingCategory
    let source: Source
}

/// Keyword rules mapping merchant and note text to a category. Instant, offline and predictable;
/// the on-device model only steps in when no rule matches.
enum KeywordCategorizer {
    private static let rules: [(category: SpendingCategory, keywords: [String])] = [
        (.groceries, ["grocery", "groceries", "supermarket", "market", "tesco", "walmart", "aldi", "lidl", "whole foods",
                      "trader joe's", "kroger", "costco", "safeway", "carrefour", "mercadona", "7-eleven", "produce"]),
        (.dining, ["coffee", "cafe", "café", "restaurant", "pizza", "burger", "starbucks", "mcdonald's", "kfc", "subway",
                   "sushi", "bar", "pub", "bakery", "takeaway", "takeout", "doordash", "uber eats", "deliveroo", "grubhub",
                   "lunch", "dinner", "breakfast", "brunch", "diner", "chipotle", "latte", "bistro"]),
        (.transport, ["uber", "lyft", "taxi", "cab", "metro", "bus", "train", "fuel", "gas", "petrol", "shell", "bp",
                      "parking", "toll", "transit", "commute"]),
        (.bills, ["electric", "electricity", "water", "internet", "phone", "utility", "utilities", "rent", "insurance",
                  "verizon", "comcast", "vodafone", "at&t", "mortgage", "broadband", "bill"]),
        (.shopping, ["amazon", "target", "ikea", "clothes", "clothing", "zara", "h&m", "nike", "mall", "shoes", "ebay", "etsy",
                     "apple", "shopping"]),
        (.health, ["pharmacy", "cvs", "walgreens", "doctor", "dentist", "hospital", "gym", "clinic", "medical", "vitamin",
                   "therapy", "optician"]),
        (.entertainment, ["netflix", "spotify", "cinema", "movie", "movies", "steam", "playstation", "concert", "hbo", "disney",
                          "youtube", "theatre", "theater", "game", "games", "hulu"]),
        (.travel, ["airline", "hotel", "airbnb", "flight", "booking.com", "expedia", "hostel", "ryanair", "delta", "trip",
                   "vacation", "holiday"])
    ]

    /// Longest keywords first, so "uber eats" wins over "uber".
    private static let ordered: [(SpendingCategory, String)] = rules
        .flatMap { rule in rule.keywords.map { (rule.category, $0) } }
        .sorted { $0.1.count > $1.1.count }

    /// The category whose keyword appears in `texts` as a whole word (or phrase), or `nil`.
    static func category(for texts: [String]) -> SpendingCategory? {
        let haystack = " " + texts.map(words).filter { !$0.isEmpty }.joined(separator: " ") + " "
        guard haystack.count > 2 else { return nil }
        for (category, keyword) in ordered {
            let needle = words(keyword)
            if haystack.contains(" \(needle) ") || haystack.contains(" \(needle)s ") {
                return category
            }
        }
        return nil
    }

    static func suggestion(merchant: String, note: String = "") -> CategorySuggestion? {
        category(for: [MerchantNameCleaner.clean(merchant), note]).map { CategorySuggestion(category: $0, source: .rule) }
    }

    /// Lower-cased, accents kept, every run of non-alphanumerics collapsed to one space.
    private static func words(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }
}
