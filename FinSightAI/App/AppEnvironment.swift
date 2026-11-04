import Foundation
import SwiftData

/// Everything the running app needs: the store and the state holder built on top of it.
@MainActor
struct AppEnvironment {
    let modelContainer: ModelContainer
    let appContext: AppContext

    /// Builds the store and services. Throws if the store can't be opened, so the app can show a
    /// recoverable error instead of crashing.
    static func make(configuration: ModelConfiguration? = nil) throws -> AppEnvironment {
        let modelContainer = try AppStoreSchema.makeContainer(configuration: try configuration ?? SharedStore.configuration())
        let modelContext = ModelContext(modelContainer)
        let capabilityService = DefaultCapabilityService()

        let appContext = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: AppleFoundationModelsInsightService(capabilityService: capabilityService),
            simulationService: DefaultSimulationService(),
            capabilityService: capabilityService,
            transactionAssistant: FoundationModelsTransactionAssistant(capabilityService: capabilityService),
            assistantService: Self.makeAssistantService(capabilityService: capabilityService)
        )
        return AppEnvironment(modelContainer: modelContainer, appContext: appContext)
    }

    private static func makeAssistantService(capabilityService: CapabilityService) -> AssistantService {
        #if DEBUG
        // Debug launch hook (`-FinSightQuickAnswersOnly YES`) that shows the chat as an ineligible
        // device sees it, for screenshots and checks on Apple Intelligence-capable Macs.
        if UserDefaults.standard.bool(forKey: "FinSightQuickAnswersOnly") {
            return QuickAnswerAssistantService(reason: .deviceNotEligible)
        }
        #endif
        #if canImport(FoundationModels)
        return OnDeviceAssistantService(engine: FoundationModelsAssistantEngine(), capabilityService: capabilityService)
        #else
        return QuickAnswerAssistantService(reason: .unsupportedSDK)
        #endif
    }
}
