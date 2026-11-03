import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class AppContext {
    private let repository: TransactionRepository
    private let recurringExpenseRepository: RecurringExpenseRepository
    let modelContext: ModelContext
    private let summaryService: SummaryService
    private let recurringSummaryService: RecurringSummaryService
    private let aiInsightService: AIInsightService
    let simulationService: SimulationService
    let capabilityService: CapabilityService
    private static let logger = Logger(subsystem: "com.finsightai.app", category: "AppContext")
    /// Most recent simulator scenarios whose explanations stay cached.
    static let simulationCacheLimit = 10
    private var isLoadingInsights = false
    private var activeSimulationFingerprint: String?
    private var isLoadingSimulationExplanation = false

    /// App-wide settings (currency, first weekday, onboarding). Loaded in `bootstrap()`.
    private(set) var settings: AppSettings?
    var transactions: [TransactionRecord] = []
    var recurringExpenses: [RecurringExpenseRecord] = []
    var sections: [TransactionMonthSection] = []
    var monthlySummary: MonthlySummary
    var recurringSummary: RecurringSummary = .empty
    /// Estimated full-month spending used as the simulator baseline.
    var monthlyRunRate: Double = 0
    var incomeSources: [IncomeSource] = []
    var budgets: [Budget] = []
    var savingsGoals: [SavingsGoal] = []
    /// This month's income against spending, for the dashboard gauge.
    var incomeGauge: IncomeGauge = .empty
    /// This month's progress for every budgeted category.
    var budgetProgress: [BudgetProgress] = []
    /// Deterministic insights still showing: engine output minus dismissed and snoozed ones.
    var engineInsights: [Insight] = []
    /// Every insight the engine produced, including hidden ones.
    var allEngineInsights: [Insight] = []
    var insightSuppressions: [InsightSuppression] = []
    var insightState: InsightLoadState = .idle
    var simulatorExplanationState: LoadableTextState = .idle
    var activeDraft: TransactionDraft = .init()
    var activeRecurringDraft: RecurringExpenseDraft = .init()
    var editingTransaction: TransactionRecord?
    var editingRecurringExpense: RecurringExpenseRecord?

    var isInsightRefreshInFlight: Bool { isLoadingInsights }
    var isSimulationRefreshInFlight: Bool { isLoadingSimulationExplanation }

    init(
        repository: TransactionRepository,
        recurringExpenseRepository: RecurringExpenseRepository,
        modelContext: ModelContext,
        summaryService: SummaryService,
        recurringSummaryService: RecurringSummaryService,
        aiInsightService: AIInsightService,
        simulationService: SimulationService,
        capabilityService: CapabilityService
    ) {
        self.repository = repository
        self.recurringExpenseRepository = recurringExpenseRepository
        self.modelContext = modelContext
        self.summaryService = summaryService
        self.recurringSummaryService = recurringSummaryService
        self.aiInsightService = aiInsightService
        self.simulationService = simulationService
        self.capabilityService = capabilityService
        self.monthlySummary = summaryService.makeMonthlySummary(from: [], recurringSummary: .empty, now: .now)
    }

    /// Loads what is stored. Never inserts data: an empty ledger stays empty until the
    /// user explicitly chooses to load sample data.
    func bootstrap() throws {
        try StoreIntegrity.dedupe(in: modelContext)
        settings = try AppSettings.fetchOrCreate(in: modelContext)
        applyCurrencySetting()
        try reloadTransactions()
    }

    func loadSampleData() throws {
        try repository.loadSampleData(now: .now)
        try loadSamplePlanning()
        try reloadTransactions()
    }

    var hasNoData: Bool {
        transactions.isEmpty && recurringExpenses.isEmpty
    }

    /// Identifies the data the insight cards are generated from. Views key their refresh
    /// task on it so insights regenerate when the underlying data changes.
    var insightsFingerprint: String {
        AIFingerprint.monthlyInsights(summary: monthlySummary)
    }

    func reloadTransactions() throws {
        transactions = try repository.fetchAllTransactions()
        recurringExpenses = try recurringExpenseRepository.fetchAllRecurringExpenses()
        recurringSummary = recurringSummaryService.makeSummary(
            recurringExpenses: recurringExpenses,
            transactions: transactions,
            now: .now
        )
        monthlyRunRate = MonthlyRunRate.estimate(from: transactions, recurringSummary: recurringSummary, now: .now)
        sections = summaryService.monthlySections(from: transactions)
        monthlySummary = summaryService.makeMonthlySummary(from: transactions, recurringSummary: recurringSummary, now: .now)
        try reloadPlanning()
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

    func saveRecurringDraft() throws {
        if let editingRecurringExpense {
            try recurringExpenseRepository.updateRecurringExpense(editingRecurringExpense, from: activeRecurringDraft)
        } else {
            try recurringExpenseRepository.addRecurringExpense(from: activeRecurringDraft)
        }
        editingRecurringExpense = nil
        activeRecurringDraft = .init()
        try reloadTransactions()
    }

    func prepareNewRecurringExpense() {
        editingRecurringExpense = nil
        activeRecurringDraft = .init()
    }

    func prepareRecurringExpense(from transaction: TransactionRecord) {
        editingRecurringExpense = nil
        activeRecurringDraft = RecurringExpenseDraft(transaction: transaction)
    }

    func prepareEdit(for recurringExpense: RecurringExpenseRecord) {
        editingRecurringExpense = recurringExpense
        activeRecurringDraft = RecurringExpenseDraft(record: recurringExpense)
    }

    func setRecurringExpense(_ recurringExpense: RecurringExpenseRecord, active: Bool) throws {
        try recurringExpenseRepository.setRecurringExpense(recurringExpense, active: active)
        try reloadTransactions()
    }

    func delete(_ recurringExpense: RecurringExpenseRecord) throws {
        try recurringExpenseRepository.deleteRecurringExpense(recurringExpense)
        try reloadTransactions()
    }

    func loadInsights(forceRefresh: Bool = false) async {
        while isLoadingInsights {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        guard monthlySummary.transactionCount > 0 else {
            insightState = .empty
            return
        }
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

        let shouldRefresh = shouldRefreshInsights(
            record: fetchCacheRecord(cacheKey: cacheKey, feature: .monthlyInsights),
            fingerprint: fingerprint,
            dayKey: dayKey,
            forceRefresh: forceRefresh
        )

        guard shouldRefresh else { return }
        isLoadingInsights = true
        defer { isLoadingInsights = false }
        let summary = monthlySummary

        do {
            let existingCachedCards: [InsightCard]
            let existingLastUpdated = currentInsightLastUpdated
            if case .available(let content) = insightState {
                existingCachedCards = content.value
            } else {
                existingCachedCards = []
            }

            let payload = try await aiInsightService.generateInsights(
                from: summary,
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
        } catch is CancellationError {
            restoreInsightStateAfterCancellation(cacheKey: cacheKey)
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

    private func restoreInsightStateAfterCancellation(cacheKey: String) {
        if let record = fetchCacheRecord(cacheKey: cacheKey, feature: .monthlyInsights),
           let cards = decodeInsightCards(from: record) {
            insightState = .available(
                CachedContent(value: cards, lastUpdated: record.generatedAt, isRefreshing: false, statusMessage: record.failureMessage)
            )
        } else {
            insightState = .idle
        }
    }

    func loadSimulationExplanation(input: SimulationInput, forceRefresh: Bool = false) async {
        let projection = simulationService.project(input: input)
        let fingerprint = AIFingerprint.simulation(input: input, projection: projection)
        let cacheKey = AICacheKey.simulationExplanation(fingerprint: fingerprint)
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
        } catch is CancellationError {
            // A newer scenario superseded this one; its own load updates the UI.
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
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            Self.logger.error("Failed to fetch AI cache record \(cacheKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveCache(_ context: String) {
        do {
            try modelContext.save()
        } catch {
            Self.logger.error("Failed to persist AI cache (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps only the most recent simulator scenarios so the cache cannot grow without bound.
    private func pruneSimulationCache() {
        let feature = AICacheFeature.simulationExplanation.rawValue
        let descriptor = FetchDescriptor<AIResponseCacheRecord>(
            predicate: #Predicate { $0.featureRawValue == feature },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do {
            let records = try modelContext.fetch(descriptor)
            guard records.count > Self.simulationCacheLimit else { return }
            for stale in records.dropFirst(Self.simulationCacheLimit) {
                modelContext.delete(stale)
            }
            saveCache("prune simulation cache")
        } catch {
            Self.logger.error("Failed to prune simulation cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func decodeInsightCards(from record: AIResponseCacheRecord) -> [InsightCard]? {
        do {
            let generatedCards = try AICacheCodec.decodeInsights(from: record.payload)
            return generatedCards.map { InsightCard(kind: $0.kind, markdown: $0.markdown) }
        } catch {
            Self.logger.error("Failed to decode cached insights: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func upsertInsightsCache(
        cacheKey: String,
        fingerprint: String,
        payload: GeneratedInsightPayload,
        dayKey: String
    ) -> AIResponseCacheRecord {
        let encoded: String
        do {
            encoded = try AICacheCodec.encodeInsights(payload.cards)
        } catch {
            Self.logger.error("Failed to encode insight cards: \(error.localizedDescription, privacy: .public)")
            encoded = "[]"
        }
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
        saveCache("upsert")
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
        saveCache("upsert")
        pruneSimulationCache()
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
            saveCache("record failure")

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
            saveCache("record failure")

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
