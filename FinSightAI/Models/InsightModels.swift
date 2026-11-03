import Foundation
import CryptoKit
import SwiftData

enum InsightKind: String, CaseIterable, Identifiable, Codable {
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

    /// What this card should concentrate on; used to brief the model in one pass.
    var focus: String {
        switch self {
        case .budgeting: "spot overspending categories or anomalies and give concise, practical budgeting suggestions."
        case .risk: "flag risk signals such as rising expenses or concentration in a few categories; be direct but constructive."
        case .growth: "suggest realistic improvements that help the user save more or redirect spending."
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
    let markdown: String
}

struct CachedContent<Value: Equatable>: Equatable {
    let value: Value
    let lastUpdated: Date
    let isRefreshing: Bool
    let statusMessage: String?
}

enum InsightLoadState: Equatable {
    case idle
    case loading
    /// Nothing logged yet, so there is nothing to analyse.
    case empty
    case available(CachedContent<[InsightCard]>)
    case unavailable(String)
    case failure(String)
}

enum LoadableTextState: Equatable {
    case idle
    case loading
    case available(CachedContent<String>)
    case unavailable(String)
    case failure(String)
}

enum AICacheFeature: String, Codable {
    case monthlyInsights
    case simulationExplanation
}

enum RefreshTrigger {
    case automatic
    case manual
}

struct GeneratedInsightCard: Codable, Equatable {
    let kind: InsightKind
    let markdown: String
}

struct GeneratedInsightPayload: Equatable {
    let cards: [GeneratedInsightCard]
    let providerIdentifier: String
}

struct GeneratedSimulationExplanation: Equatable {
    let markdown: String
    let providerIdentifier: String
}

enum AIFingerprint {
    static func monthlyInsights(summary: MonthlySummary) -> String {
        let categoryBreakdown = summary.categoryBreakdown
            .map {
                "\($0.category.rawValue):\(normalizedDecimal($0.amount)):\(normalizedDecimal($0.percentage))"
            }
            .joined(separator: "|")

        return [
            "month=\(MonthFormatter.sectionID(for: summary.monthStart))",
            "total=\(normalizedDecimal(summary.totalSpent))",
            "recurring=\(normalizedDecimal(summary.recurringMonthlySpend))",
            "recurringCount=\(summary.recurringTransactionCount)",
            "oneOff=\(normalizedDecimal(summary.oneOffSpent))",
            "count=\(summary.transactionCount)",
            "average=\(normalizedDecimal(summary.averageTransactionValue))",
            "top=\(summary.topCategory?.rawValue ?? "none")",
            "topShare=\(normalizedDecimal(summary.topCategoryShare))",
            "trend=\(summary.spendingTrendDescription)",
            "breakdown=\(categoryBreakdown)"
        ].joined(separator: ";")
    }

    static func simulation(input: SimulationInput, projection: SimulationProjection) -> String {
        [
            "runRate=\(normalizedDecimal(input.monthlyRunRate))",
            "recurring=\(normalizedDecimal(input.recurringMonthlySpend))",
            "daily=\(normalizedDecimal(input.dailySavings))",
            "reduction=\(normalizedDecimal(input.reductionPercent))",
            "goal=\(normalizedDecimal(input.savingsGoal))",
            "pausedRecurring=\(normalizedDecimal(input.pausedRecurringMonthlySpend))",
            "monthly=\(normalizedDecimal(projection.monthlySavings))",
            "three=\(normalizedDecimal(projection.projectedSavingsThreeMonths))",
            "six=\(normalizedDecimal(projection.projectedSavingsSixMonths))",
            "twelve=\(normalizedDecimal(projection.projectedSavingsTwelveMonths))",
            "monthsToGoal=\(projection.monthsToGoal.map(String.init) ?? "none")"
        ].joined(separator: ";")
    }

    private static func normalizedDecimal(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

enum AICacheKey {
    static func monthlyInsights(for summary: MonthlySummary) -> String {
        "monthly-insights:\(MonthFormatter.sectionID(for: summary.monthStart))"
    }

    /// Each scenario gets its own cache entry, so one scenario never overwrites (or is shown as)
    /// another. `fingerprint` is the scenario's `AIFingerprint.simulation` string.
    static func simulationExplanation(fingerprint: String) -> String {
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(simulationPrefix)\(hex)"
    }

    static let simulationPrefix = "simulation-explanation:"
}

enum AICacheCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encodeInsights(_ cards: [GeneratedInsightCard]) throws -> String {
        let data = try encoder.encode(cards)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return string
    }

    static func decodeInsights(from payload: String) throws -> [GeneratedInsightCard] {
        guard let data = payload.data(using: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try decoder.decode([GeneratedInsightCard].self, from: data)
    }
}

enum AIRefreshPolicy {
    static func needsAutomaticRefresh(
        record: AIResponseCacheRecord,
        fingerprint: String,
        currentDayKey: String
    ) -> Bool {
        if record.sourceFingerprint != fingerprint {
            return true
        }

        return record.lastAutoRefreshDayKey != currentDayKey
    }
}
