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
