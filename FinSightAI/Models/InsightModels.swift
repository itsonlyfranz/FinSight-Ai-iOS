import Foundation
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

@Model
final class AIResponseCacheRecord {
    @Attribute(.unique) var cacheKey: String
    var featureRawValue: String
    var sourceFingerprint: String
    var payload: String
    var generatedAt: Date
    var lastAutoRefreshDayKey: String?
    var providerIdentifier: String
    var failureMessage: String?
    var updatedAt: Date

    init(
        cacheKey: String,
        feature: AICacheFeature,
        sourceFingerprint: String,
        payload: String,
        generatedAt: Date,
        lastAutoRefreshDayKey: String? = nil,
        providerIdentifier: String,
        failureMessage: String? = nil,
        updatedAt: Date = .now
    ) {
        self.cacheKey = cacheKey
        self.featureRawValue = feature.rawValue
        self.sourceFingerprint = sourceFingerprint
        self.payload = payload
        self.generatedAt = generatedAt
        self.lastAutoRefreshDayKey = lastAutoRefreshDayKey
        self.providerIdentifier = providerIdentifier
        self.failureMessage = failureMessage
        self.updatedAt = updatedAt
    }

    var feature: AICacheFeature {
        get { AICacheFeature(rawValue: featureRawValue) ?? .monthlyInsights }
        set { featureRawValue = newValue.rawValue }
    }
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
            "current=\(normalizedDecimal(input.currentMonthlySpending))",
            "daily=\(normalizedDecimal(input.dailySavings))",
            "reduction=\(normalizedDecimal(input.reductionPercent))",
            "goal=\(normalizedDecimal(input.savingsGoal))",
            "disabledRecurring=\(normalizedDecimal(input.disabledRecurringMonthlySpend))",
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

    static func simulationExplanation() -> String {
        "simulation-explanation"
    }
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
