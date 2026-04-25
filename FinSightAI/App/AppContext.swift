import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppContext {
    private let repository: TransactionRepository
    private let modelContext: ModelContext
    private let summaryService: SummaryService
    private let aiInsightService: AIInsightService
    let simulationService: SimulationService
    let capabilityService: CapabilityService
    private var isLoadingInsights = false
    private var activeSimulationFingerprint: String?
    private var isLoadingSimulationExplanation = false

    var transactions: [TransactionRecord] = []
    var sections: [TransactionMonthSection] = []
    var monthlySummary: MonthlySummary
    var insightState: InsightLoadState = .idle
    var simulatorExplanationState: LoadableTextState = .idle
    var activeDraft: TransactionDraft = .init()
    var editingTransaction: TransactionRecord?

    var isInsightRefreshInFlight: Bool { isLoadingInsights }
    var isSimulationRefreshInFlight: Bool { isLoadingSimulationExplanation }

    init(
        repository: TransactionRepository,
        modelContext: ModelContext,
        summaryService: SummaryService,
        aiInsightService: AIInsightService,
        simulationService: SimulationService,
        capabilityService: CapabilityService
    ) {
        self.repository = repository
        self.modelContext = modelContext
        self.summaryService = summaryService
        self.aiInsightService = aiInsightService
        self.simulationService = simulationService
        self.capabilityService = capabilityService
        self.monthlySummary = summaryService.makeMonthlySummary(from: [], now: .now)
    }

    func bootstrap() throws {
        try repository.seedIfNeeded()
        try reloadTransactions()
    }

    func reloadTransactions() throws {
        transactions = try repository.fetchAllTransactions()
        sections = summaryService.monthlySections(from: transactions)
        monthlySummary = summaryService.makeMonthlySummary(from: transactions, now: .now)
    }

    func saveDraft() throws {
        if let editingTransaction {
            try repository.updateTransaction(editingTransaction, from: activeDraft)
        } else {
            try repository.addTransaction(from: activeDraft)
        }
        editingTransaction = nil
        activeDraft = .init()
        try reloadTransactions()
    }

    func prepareNewTransaction() {
        editingTransaction = nil
        activeDraft = .init()
    }

    func prepareEdit(for transaction: TransactionRecord) {
        editingTransaction = transaction
        activeDraft = TransactionDraft(record: transaction)
    }

    func delete(_ transaction: TransactionRecord) throws {
        try repository.deleteTransaction(transaction)
        try reloadTransactions()
    }

    func loadInsights(forceRefresh: Bool = false) async {
        let cacheKey = AICacheKey.monthlyInsights(for: monthlySummary)
        let fingerprint = AIFingerprint.monthlyInsights(summary: monthlySummary)
        let dayKey = DayFormatter.dayKey(for: .now)

        if let record = fetchCacheRecord(cacheKey: cacheKey, feature: .monthlyInsights),
           let cachedCards = decodeInsightCards(from: record) {
            insightState = .available(
                CachedContent(
                    value: cachedCards,
                    lastUpdated: record.generatedAt,
                    isRefreshing: shouldRefreshInsights(record: record, fingerprint: fingerprint, dayKey: dayKey, forceRefresh: forceRefresh),
                    statusMessage: record.failureMessage
                )
            )
        } else {
            insightState = .loading
        }

        guard !isLoadingInsights else { return }

        let shouldRefresh = shouldRefreshInsights(
            record: fetchCacheRecord(cacheKey: cacheKey, feature: .monthlyInsights),
            fingerprint: fingerprint,
            dayKey: dayKey,
            forceRefresh: forceRefresh
        )

        guard shouldRefresh else { return }
        isLoadingInsights = true
        defer { isLoadingInsights = false }

        do {
            let existingCachedCards: [InsightCard]
            let existingLastUpdated = currentInsightLastUpdated
            if case .available(let content) = insightState {
                existingCachedCards = content.value
            } else {
                existingCachedCards = []
            }

            let payload = try await aiInsightService.generateInsights(
                from: monthlySummary,
                onUpdate: { [weak self] partialCards in
                    guard let self else { return }
                    await MainActor.run {
                        let cards = partialCards.map { InsightCard(kind: $0.kind, markdown: $0.markdown) }
                        let visibleCards = cards.isEmpty ? existingCachedCards : cards
                        self.insightState = .available(
                            CachedContent(
                                value: visibleCards,
                                lastUpdated: (visibleCards == existingCachedCards
                                    ? (existingLastUpdated ?? .now)
                                    : .now),
                                isRefreshing: true,
                                statusMessage: nil
                            )
                        )
                    }
                }
            )
            let record = upsertInsightsCache(
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                payload: payload,
                dayKey: dayKey
            )
            insightState = .available(
                CachedContent(
                    value: payload.cards.map { InsightCard(kind: $0.kind, markdown: $0.markdown) },
                    lastUpdated: record.generatedAt,
                    isRefreshing: false,
                    statusMessage: nil
                )
            )
        } catch let error as AIInsightError {
            handleInsightRefreshFailure(
                cacheKey: cacheKey,
                feature: .monthlyInsights,
                dayKey: dayKey,
                message: error.localizedDescription,
                isAutomatic: !forceRefresh
            )
        } catch {
            handleInsightRefreshFailure(
                cacheKey: cacheKey,
                feature: .monthlyInsights,
                dayKey: dayKey,
                message: error.localizedDescription,
                isAutomatic: !forceRefresh
            )
        }
    }

    func loadSimulationExplanation(input: SimulationInput, forceRefresh: Bool = false) async {
        let projection = simulationService.project(input: input)
        let cacheKey = AICacheKey.simulationExplanation()
        let fingerprint = AIFingerprint.simulation(input: input, projection: projection)
        let dayKey = DayFormatter.dayKey(for: .now)

        if let record = fetchCacheRecord(cacheKey: cacheKey, feature: .simulationExplanation) {
            simulatorExplanationState = .available(
                CachedContent(
                    value: record.payload,
                    lastUpdated: record.generatedAt,
                    isRefreshing: shouldRefreshSimulation(record: record, fingerprint: fingerprint, dayKey: dayKey, forceRefresh: forceRefresh),
                    statusMessage: record.failureMessage
                )
            )
        } else {
            simulatorExplanationState = .loading
        }

        if isLoadingSimulationExplanation, activeSimulationFingerprint == fingerprint {
            return
        }

        let shouldRefresh = shouldRefreshSimulation(
            record: fetchCacheRecord(cacheKey: cacheKey, feature: .simulationExplanation),
            fingerprint: fingerprint,
            dayKey: dayKey,
            forceRefresh: forceRefresh
        )

        guard shouldRefresh else { return }
        isLoadingSimulationExplanation = true
        activeSimulationFingerprint = fingerprint
        defer {
            isLoadingSimulationExplanation = false
            activeSimulationFingerprint = nil
        }

        do {
            let existingCachedMarkdown: String?
            let existingLastUpdated = currentSimulationLastUpdated
            if case .available(let content) = simulatorExplanationState {
                existingCachedMarkdown = content.value
            } else {
                existingCachedMarkdown = nil
            }

            let explanation = try await aiInsightService.explainSimulation(
                input: input,
                projection: projection,
                onUpdate: { [weak self] partialMarkdown in
                    guard let self else { return }
                    let visibleMarkdown = partialMarkdown.isEmpty ? (existingCachedMarkdown ?? "") : partialMarkdown
                    guard !visibleMarkdown.isEmpty else { return }
                    await MainActor.run {
                        self.simulatorExplanationState = .available(
                            CachedContent(
                                value: visibleMarkdown,
                                lastUpdated: (existingCachedMarkdown == visibleMarkdown
                                    ? (existingLastUpdated ?? .now)
                                    : .now),
                                isRefreshing: true,
                                statusMessage: nil
                            )
                        )
                    }
                }
            )
            let record = upsertSimulationCache(
                cacheKey: cacheKey,
                fingerprint: fingerprint,
                explanation: explanation,
                dayKey: dayKey
            )
            simulatorExplanationState = .available(
                CachedContent(
                    value: record.payload,
                    lastUpdated: record.generatedAt,
                    isRefreshing: false,
                    statusMessage: nil
                )
            )
        } catch let error as AIInsightError {
            handleSimulationRefreshFailure(
                cacheKey: cacheKey,
                dayKey: dayKey,
                message: error.localizedDescription,
                isAutomatic: !forceRefresh
            )
        } catch {
            handleSimulationRefreshFailure(
                cacheKey: cacheKey,
                dayKey: dayKey,
                message: error.localizedDescription,
                isAutomatic: !forceRefresh
            )
        }
    }

    private func shouldRefreshInsights(
        record: AIResponseCacheRecord?,
        fingerprint: String,
        dayKey: String,
        forceRefresh: Bool
    ) -> Bool {
        if forceRefresh {
            return true
        }

        guard let record else {
            return true
        }

        return AIRefreshPolicy.needsAutomaticRefresh(record: record, fingerprint: fingerprint, currentDayKey: dayKey)
    }

    private func shouldRefreshSimulation(
        record: AIResponseCacheRecord?,
        fingerprint: String,
        dayKey: String,
        forceRefresh: Bool
    ) -> Bool {
        if forceRefresh {
            return true
        }

        guard let record else {
            return true
        }

        return AIRefreshPolicy.needsAutomaticRefresh(record: record, fingerprint: fingerprint, currentDayKey: dayKey)
    }

    private func fetchCacheRecord(cacheKey: String, feature: AICacheFeature) -> AIResponseCacheRecord? {
        let descriptor = FetchDescriptor<AIResponseCacheRecord>(
            predicate: #Predicate {
                $0.cacheKey == cacheKey && $0.featureRawValue == feature.rawValue
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func decodeInsightCards(from record: AIResponseCacheRecord) -> [InsightCard]? {
        guard let generatedCards = try? AICacheCodec.decodeInsights(from: record.payload) else {
            return nil
        }
        return generatedCards.map { InsightCard(kind: $0.kind, markdown: $0.markdown) }
    }

    private func upsertInsightsCache(
        cacheKey: String,
        fingerprint: String,
        payload: GeneratedInsightPayload,
        dayKey: String
    ) -> AIResponseCacheRecord {
        let encoded = (try? AICacheCodec.encodeInsights(payload.cards)) ?? "[]"
        let record = fetchCacheRecord(cacheKey: cacheKey, feature: .monthlyInsights)
            ?? AIResponseCacheRecord(
                cacheKey: cacheKey,
                feature: .monthlyInsights,
                sourceFingerprint: fingerprint,
                payload: encoded,
                generatedAt: .now,
                providerIdentifier: payload.providerIdentifier
            )

        record.sourceFingerprint = fingerprint
        record.payload = encoded
        record.generatedAt = .now
        record.lastAutoRefreshDayKey = dayKey
        record.providerIdentifier = payload.providerIdentifier
        record.failureMessage = nil
        record.updatedAt = .now

        if record.modelContext == nil {
            modelContext.insert(record)
        }
        try? modelContext.save()
        return record
    }

    private func upsertSimulationCache(
        cacheKey: String,
        fingerprint: String,
        explanation: GeneratedSimulationExplanation,
        dayKey: String
    ) -> AIResponseCacheRecord {
        let record = fetchCacheRecord(cacheKey: cacheKey, feature: .simulationExplanation)
            ?? AIResponseCacheRecord(
                cacheKey: cacheKey,
                feature: .simulationExplanation,
                sourceFingerprint: fingerprint,
                payload: explanation.markdown,
                generatedAt: .now,
                providerIdentifier: explanation.providerIdentifier
            )

        record.sourceFingerprint = fingerprint
        record.payload = explanation.markdown
        record.generatedAt = .now
        record.lastAutoRefreshDayKey = dayKey
        record.providerIdentifier = explanation.providerIdentifier
        record.failureMessage = nil
        record.updatedAt = .now

        if record.modelContext == nil {
            modelContext.insert(record)
        }
        try? modelContext.save()
        return record
    }

    private func handleInsightRefreshFailure(
        cacheKey: String,
        feature: AICacheFeature,
        dayKey: String,
        message: String,
        isAutomatic: Bool
    ) {
        if let record = fetchCacheRecord(cacheKey: cacheKey, feature: feature),
           let cachedCards = decodeInsightCards(from: record) {
            record.failureMessage = message
            if isAutomatic {
                record.lastAutoRefreshDayKey = dayKey
            }
            record.updatedAt = .now
            try? modelContext.save()

            insightState = .available(
                CachedContent(
                    value: cachedCards,
                    lastUpdated: record.generatedAt,
                    isRefreshing: false,
                    statusMessage: message
                )
            )
        } else {
            insightState = .unavailable(message)
        }
    }

    private func handleSimulationRefreshFailure(
        cacheKey: String,
        dayKey: String,
        message: String,
        isAutomatic: Bool
    ) {
        if let record = fetchCacheRecord(cacheKey: cacheKey, feature: .simulationExplanation) {
            record.failureMessage = message
            if isAutomatic {
                record.lastAutoRefreshDayKey = dayKey
            }
            record.updatedAt = .now
            try? modelContext.save()

            simulatorExplanationState = .available(
                CachedContent(
                    value: record.payload,
                    lastUpdated: record.generatedAt,
                    isRefreshing: false,
                    statusMessage: message
                )
            )
        } else {
            simulatorExplanationState = .unavailable(message)
        }
    }

    private var currentInsightLastUpdated: Date? {
        if case .available(let content) = insightState {
            return content.lastUpdated
        }
        return nil
    }

    private var currentSimulationLastUpdated: Date? {
        if case .available(let content) = simulatorExplanationState {
            return content.lastUpdated
        }
        return nil
    }
}
