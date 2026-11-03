import Foundation
import SwiftData

/// Everything the running app needs: the store and the state holder built on top of it.
@MainActor
struct AppEnvironment {
    let modelContainer: ModelContainer
    let appContext: AppContext

    /// Builds the store and services. Throws if the store can't be opened, so the app can show a
    /// recoverable error instead of crashing.
    static func make(configuration: ModelConfiguration = ModelConfiguration(isStoredInMemoryOnly: false)) throws -> AppEnvironment {
        let modelContainer = try ModelContainer(for: AppStoreSchema.schema, configurations: configuration)
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
            capabilityService: capabilityService
        )
        return AppEnvironment(modelContainer: modelContainer, appContext: appContext)
    }
}
