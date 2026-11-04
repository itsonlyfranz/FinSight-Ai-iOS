import AppIntents
import Observation

enum ExpenseDestination: String, AppEnum {
    case expense
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "FinSight Screen"
    static let caseDisplayRepresentations: [ExpenseDestination: DisplayRepresentation] = [.expense: "New Expense"]
}

@MainActor
@Observable
final class ExpenseNavigation {
    static let shared = ExpenseNavigation()
    var requested = false
}

struct OpenExpenseControlIntent: OpenIntent {
    static let title: LocalizedStringResource = "Add FinSight Expense"
    @Parameter(title: "Screen") var target: ExpenseDestination
    init() { target = .expense }
    @MainActor
    func perform() async throws -> some IntentResult {
        ExpenseNavigation.shared.requested = true
        return .result()
    }
}
