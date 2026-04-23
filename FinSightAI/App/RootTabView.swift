import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.xyaxis.line")
                }

            TransactionsView()
                .tabItem {
                    Label("Transactions", systemImage: "list.bullet.rectangle")
                }

            InsightsView()
                .tabItem {
                    Label("Insights", systemImage: "sparkles.rectangle.stack.fill")
                }

            SimulatorView()
                .tabItem {
                    Label("Simulator", systemImage: "slider.horizontal.3")
                }
        }
        .tint(AppTheme.primary)
    }
}
