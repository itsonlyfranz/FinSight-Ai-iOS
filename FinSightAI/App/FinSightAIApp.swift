import SwiftData
import SwiftUI

@main
struct FinSightAIApp: App {
    private let modelContainer: ModelContainer
    @State private var appContext: AppContext

    init() {
        let schema = Schema([TransactionRecord.self, RecurringExpenseRecord.self, AIResponseCacheRecord.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Unable to create model container: \(error.localizedDescription)")
        }

        let modelContext = ModelContext(modelContainer)
        let capabilityService = DefaultCapabilityService()
        let aiService: AIInsightService

        switch capabilityService.aiAvailability {
        case .available:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                aiService = AppleFoundationModelsInsightService()
            } else {
                aiService = UnsupportedAIInsightService(reason: "Apple Intelligence needs iOS 26 or newer.")
            }
            #else
            aiService = UnsupportedAIInsightService(reason: "Apple Intelligence requires a newer Apple SDK than the one used to build this app.")
            #endif
        case .unavailable(let message):
            aiService = UnsupportedAIInsightService(reason: message)
        }

        _appContext = State(
            initialValue: AppContext(
                repository: SwiftDataTransactionRepository(modelContext: modelContext),
                recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
                modelContext: modelContext,
                summaryService: DefaultSummaryService(),
                recurringSummaryService: DefaultRecurringSummaryService(),
                aiInsightService: aiService,
                simulationService: DefaultSimulationService(),
                capabilityService: capabilityService
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appContext)
                .modelContainer(modelContainer)
                .task {
                    do {
                        try appContext.bootstrap()
                    } catch {
                        assertionFailure("Bootstrap failed: \(error.localizedDescription)")
                    }
                }
        }
    }
}
