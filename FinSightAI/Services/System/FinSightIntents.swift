import AppIntents
import Observation
import SwiftData
import WidgetKit

struct LogExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Expense"
    static let description = IntentDescription("Save an expense in your on-device FinSight ledger.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Amount") var amount: Double
    @Parameter(title: "Merchant") var merchant: String
    static var parameterSummary: some ParameterSummary { Summary("Log \(\.$amount) at \(\.$merchant)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try SharedStore.open()
        let context = ModelContext(container)
        try ExpenseIntentService.log(amount: amount, merchant: merchant, in: context)
        WidgetCenter.shared.reloadAllTimelines()
        if let snapshot = try? SystemSnapshot.load() { try? await NudgeScheduler.refresh(snapshot: snapshot) }
        return .result(dialog: "Expense saved in FinSight AI.")
    }
}

enum ExpenseIntentService {
    @MainActor
    static func log(amount: Double, merchant: String, in context: ModelContext, date: Date = .now) throws {
        let validated = try validate(amount: amount, merchant: merchant)
        context.insert(TransactionRecord(amount: validated, kind: .expense,
            merchantName: merchant.trimmingCharacters(in: .whitespacesAndNewlines), category: .other, date: date, note: ""))
        try context.save()
    }

    static func validate(amount: Double, merchant: String) throws -> Decimal {
        guard amount.isFinite, !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.invalidAmount }
        return try ValidationError.validatedAmount(Decimal(string: String(amount)))
    }
}

struct SpendThisMonthIntent: AppIntent {
    static let title: LocalizedStringResource = "Spend This Month"
    static let description = IntentDescription("Read your month-to-date spending from FinSight AI.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = try SystemSnapshot.load()
        return .result(dialog: "You've spent \(snapshot.spendText) this month.")
    }
}

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

struct FinSightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogExpenseIntent(), phrases: ["Log an expense in \(.applicationName)"], shortTitle: "Log Expense", systemImageName: "plus.circle")
        AppShortcut(intent: SpendThisMonthIntent(), phrases: ["How much did I spend in \(.applicationName)"], shortTitle: "Month Spending", systemImageName: "chart.pie")
        AppShortcut(intent: OpenExpenseControlIntent(), phrases: ["Add expense with \(.applicationName)"], shortTitle: "Add Expense", systemImageName: "plus")
    }
}
