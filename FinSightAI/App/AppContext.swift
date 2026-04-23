import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppContext {
    private let repository: TransactionRepository
    private let summaryService: SummaryService
    private let aiInsightService: AIInsightService
    let simulationService: SimulationService
    let capabilityService: CapabilityService

    var transactions: [TransactionRecord] = []
    var sections: [TransactionMonthSection] = []
    var monthlySummary: MonthlySummary
    var insightState: InsightLoadState = .idle
    var simulatorExplanationState: LoadableTextState = .idle
    var activeDraft: TransactionDraft = .init()
    var editingTransaction: TransactionRecord?

    init(
        repository: TransactionRepository,
        summaryService: SummaryService,
        aiInsightService: AIInsightService,
        simulationService: SimulationService,
        capabilityService: CapabilityService
    ) {
        self.repository = repository
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

    func loadInsights() async {
        insightState = .loading

        do {
            let insights = try await aiInsightService.generateInsights(from: monthlySummary)
            insightState = .available(insights)
        } catch let error as AIInsightError {
            insightState = .unavailable(error.localizedDescription)
        } catch {
            insightState = .failure(error.localizedDescription)
        }
    }

    func loadSimulationExplanation(input: SimulationInput) async {
        simulatorExplanationState = .loading

        let projection = simulationService.project(input: input)

        do {
            let explanation = try await aiInsightService.explainSimulation(input: input, projection: projection)
            simulatorExplanationState = .loaded(explanation)
        } catch let error as AIInsightError {
            simulatorExplanationState = .unavailable(error.localizedDescription)
        } catch {
            simulatorExplanationState = .failure(error.localizedDescription)
        }
    }
}

enum LoadableTextState: Equatable {
    case idle
    case loading
    case loaded(String)
    case unavailable(String)
    case failure(String)
}
