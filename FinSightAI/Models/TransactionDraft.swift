import Foundation

struct TransactionDraft: Equatable {
    var amountText = ""
    var kind: TransactionKind = .expense
    var merchantName = ""
    var category: SpendingCategory = .groceries
    var date = Date()
    var note = ""
    var locale: Locale = .current

    init() {}

    init(record: TransactionRecord) {
        amountText = CurrencyFormatter.plainNumberString(from: record.amount, locale: locale)
        kind = record.kind
        merchantName = record.merchantName
        category = record.category
        date = record.date
        note = record.note
    }

    var amount: Decimal? {
        AmountParser.parse(amountText, locale: locale)
    }

    var validationError: String? {
        guard let amount else { return "Enter a valid amount." }
        guard amount > 0 else { return "Amount must be greater than zero." }
        guard !merchantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Merchant is required."
        }
        return nil
    }
}
