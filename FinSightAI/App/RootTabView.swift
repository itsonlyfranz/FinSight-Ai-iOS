import SwiftUI
import OSLog

struct RootTabView: View {
    @Environment(AppContext.self) private var appContext

    @State private var navigation = ExpenseNavigation.shared
    @State private var showingExpense = false
    @State private var errorMessage: String?

    var body: some View {
        // Changing the currency in Settings rebuilds the amount-showing tabs so every figure is
        // reformatted; Settings itself keeps its state.
        TabView {
            DashboardView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Dashboard", systemImage: "chart.xyaxis.line")
                }

            TransactionsView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.rectangle")
                }

            InsightsView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Insights", systemImage: "sparkles.rectangle.stack.fill")
                }

            SimulatorView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Simulator", systemImage: "slider.horizontal.3")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(AppTheme.primary)
        .onChange(of: navigation.requested, initial: true) { _, requested in
            if requested {
                appContext.prepareNewTransaction()
                showingExpense = true
                navigation.requested = false
            }
        }
        .onOpenURL { url in
            if url.scheme == "finsight", url.host == "expense" {
                appContext.prepareNewTransaction()
                showingExpense = true
            }
        }
        .sheet(isPresented: $showingExpense) {
            TransactionEditorView(onSave: {
                do { try appContext.saveDraft(); showingExpense = false }
                catch { errorMessage = error.localizedDescription }
            }).environment(appContext)
        }
        .alert("Unable to save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .task(id: appContext.systemRefreshToken) {
            do { try await NudgeScheduler.refresh(snapshot: .make(context: appContext)) }
            catch is CancellationError { }
            catch { Logger(subsystem: "com.finsightai.app", category: "Reminders").error("Reminder refresh failed: \(error.localizedDescription)") }
        }
    }
}
