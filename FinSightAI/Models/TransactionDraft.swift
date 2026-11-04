import Foundation

struct TransactionDraft: Equatable {
    var amountText = ""
    var kind: TransactionKind = .expense
    var merchantName = ""
    var category: SpendingCategory = .groceries
    var date = Date()
    var note = ""
    var locale: Locale = .current
    /// True once the category was picked by the user (or read from their own words), so automatic
    /// suggestions never overwrite it.
    var categoryIsUserChosen = false

    init() {}

    init(record: TransactionRecord) {
        amountText = CurrencyFormatter.plainNumberString(from: record.amount, locale: locale)
        kind = record.kind
        merchantName = record.merchantName
        category = record.category
        date = record.date
        note = record.note
        categoryIsUserChosen = true
    }

    var amount: Decimal? {
        AmountParser.parse(amountText, locale: locale)
    }

    var validationError: String? {
        guard let amount else { return String(localized: "Enter a valid amount.") }
        guard amount > 0 else { return String(localized: "Amount must be greater than zero.") }
        guard !merchantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (kind == .income ? String(localized: "Source is required.") : String(localized: "Merchant is required."))
        }
        return nil
    }
}
