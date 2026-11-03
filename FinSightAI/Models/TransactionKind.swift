import Foundation

/// What a transaction means for the user's money.
///
/// Amount semantics: a transaction's stored `amount` is always a **non-negative magnitude**. The
/// direction comes from the kind, which makes the sign explicit and impossible to get wrong:
///
/// | kind       | `signedAmount` | counts as spending | counts as income |
/// |------------|----------------|--------------------|------------------|
/// | `expense`  | `-amount`      | yes (unless the category is savings) | no |
/// | `income`   | `+amount`      | no                 | yes              |
/// | `transfer` | `0`            | no                 | no               |
///
/// A transfer moves money between the user's own accounts or into savings, so it changes neither
/// spending nor income and has no net effect on cash flow.
enum TransactionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case expense
    case income
    case transfer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: "Expense"
        case .income: "Income"
        case .transfer: "Transfer"
        }
    }

    /// Cash-flow effect of a (non-negative) magnitude.
    func signedAmount(for magnitude: Decimal) -> Decimal {
        switch self {
        case .expense: -magnitude
        case .income: magnitude
        case .transfer: 0
        }
    }
}
