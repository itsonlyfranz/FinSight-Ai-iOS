import SwiftUI
import OSLog

struct RootTabView: View {
    @Environment(AppContext.self) private var appContext

    @State private var navigation = ExpenseNavigation.shared
    @State private var showingExpense = false
    @State private var errorMessage: String?
    @State private var selectedTab = Tab.dashboard
    @State private var savedCount = 0
    @AppStorage(ThemePalette.storageKey) private var paletteRawValue = ThemePalette.deckEmerald.rawValue

    private enum Tab: Hashable { case dashboard, transactions, insights, simulator, settings }

    var body: some View {
        // Changing the currency in Settings rebuilds the amount-showing tabs so every figure is
        // reformatted; Settings itself keeps its state. A theme change rebuilds every tab so all
        // colours follow the new palette, keeping the selected tab.
        TabView(selection: $selectedTab) {
            DashboardView(openSimulator: { selectedTab = .simulator }, openInsights: { selectedTab = .insights })
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Dashboard", systemImage: "chart.xyaxis.line")
                }
                .tag(Tab.dashboard)

            TransactionsView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.rectangle")
                }
                .tag(Tab.transactions)

            InsightsView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Insights", systemImage: "sparkles.rectangle.stack.fill")
                }
                .tag(Tab.insights)

            SimulatorView()
                .id(appContext.currencyCode)
                .tabItem {
                    Label("Simulator", systemImage: "slider.horizontal.3")
                }
                .tag(Tab.simulator)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(Tab.settings)
        }
        .id(paletteRawValue)
        .tint(AppTheme.primary)
        .sensoryFeedback(.selection, trigger: selectedTab)
        .sensoryFeedback(.success, trigger: savedCount)
        .fullScreenCover(isPresented: Binding(get: { appContext.needsOnboarding }, set: { _ in })) {
            OnboardingView(initialStep: Self.launchOnboardingStep)
                .environment(appContext)
        }
        .onChange(of: navigation.requested, initial: true) { _, requested in
            if requested {
                if !appContext.isTransactionEditorOpen {
                    appContext.prepareNewTransaction()
                    showingExpense = true
                }
                navigation.requested = false
            }
        }
        .sheet(isPresented: $showingExpense) {
            TransactionEditorView(onSave: {
                do { try appContext.saveDraft(); showingExpense = false; savedCount += 1 }
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

    /// Debug builds can open onboarding at a given step (`-FinSightOnboardingStep 3`) for screenshots.
    private static var launchOnboardingStep: OnboardingDraft.Step {
        #if DEBUG
        OnboardingDraft.Step(rawValue: UserDefaults.standard.integer(forKey: "FinSightOnboardingStep")) ?? .welcome
        #else
        .welcome
        #endif
    }
}
