import Foundation

enum InsightKind: String, CaseIterable, Identifiable {
    case budgeting
    case risk
    case growth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .budgeting: "Budgeting"
        case .risk: "Risk"
        case .growth: "Growth"
        }
    }

    var systemImage: String {
        switch self {
        case .budgeting: "list.clipboard.fill"
        case .risk: "exclamationmark.triangle.fill"
        case .growth: "chart.line.uptrend.xyaxis"
        }
    }
}

struct InsightCard: Identifiable, Equatable {
    let id = UUID()
    let kind: InsightKind
    let body: String
}

enum InsightLoadState: Equatable {
    case idle
    case loading
    case available([InsightCard])
    case unavailable(String)
    case failure(String)
}
