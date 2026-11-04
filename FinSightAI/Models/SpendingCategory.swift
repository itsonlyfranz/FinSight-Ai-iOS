import SwiftUI

enum SpendingCategory: String, CaseIterable, Codable, Identifiable {
    case groceries
    case dining
    case transport
    case bills
    case shopping
    case health
    case entertainment
    case savings
    case travel
    case other

    var id: String { rawValue }

    /// Savings are money set aside, not money spent, so they never count toward spending totals.
    var countsAsSpending: Bool { self != .savings }

    var title: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Dining"
        case .transport: "Transport"
        case .bills: "Bills"
        case .shopping: "Shopping"
        case .health: "Health"
        case .entertainment: "Entertainment"
        case .savings: "Savings"
        case .travel: "Travel"
        case .other: "Other"
        }
    }

    /// The name shown in the interface, in the person's language. `title` stays English because
    /// it feeds insight text, AI prompts and exports.
    var localizedTitle: String {
        switch self {
        case .groceries: String(localized: "Groceries")
        case .dining: String(localized: "Dining")
        case .transport: String(localized: "Transport")
        case .bills: String(localized: "Bills")
        case .shopping: String(localized: "Shopping")
        case .health: String(localized: "Health")
        case .entertainment: String(localized: "Entertainment")
        case .savings: String(localized: "Savings")
        case .travel: String(localized: "Travel")
        case .other: String(localized: "Other")
        }
    }

    var symbolName: String {
        switch self {
        case .groceries: "cart.fill"
        case .dining: "fork.knife"
        case .transport: "car.fill"
        case .bills: "doc.text.fill"
        case .shopping: "bag.fill"
        case .health: "cross.case.fill"
        case .entertainment: "sparkles.tv.fill"
        case .savings: "banknote.fill"
        case .travel: "airplane"
        case .other: "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .groceries: Color.green
        case .dining: Color.orange
        case .transport: Color.blue
        case .bills: Color.purple
        case .shopping: Color.pink
        case .health: Color.red
        case .entertainment: Color.indigo
        case .savings: Color.teal
        case .travel: Color.cyan
        case .other: Color.gray
        }
    }
}
