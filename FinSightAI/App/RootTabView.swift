import SwiftUI

struct RootTabView: View {
    @Environment(AppContext.self) private var appContext

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
    }
}
