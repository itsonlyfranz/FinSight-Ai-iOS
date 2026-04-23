import Charts
import SwiftUI

struct DashboardView: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroCard
                    spendingChartCard
                    recentTransactionsCard
                    insightCard
                }
                .padding(20)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("FinSight AI")
        }
        .task(id: appContext.monthlySummary.monthLabel) {
            await appContext.loadInsights()
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appContext.monthlySummary.monthLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)

            Text(CurrencyFormatter.pesoString(from: appContext.monthlySummary.totalSpent))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.ink)

            HStack(spacing: 12) {
                metricPill(title: "Transactions", value: "\(appContext.monthlySummary.transactionCount)")
                metricPill(title: "Average", value: CurrencyFormatter.pesoString(from: appContext.monthlySummary.averageTransactionValue))
            }

            Text(appContext.monthlySummary.spendingTrendDescription)
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var spendingChartCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Category Breakdown")
                .font(.headline)

            if appContext.monthlySummary.categoryBreakdown.isEmpty {
                ContentUnavailableView("No spend yet", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity)
            } else {
                Chart(appContext.monthlySummary.categoryBreakdown) { item in
                    BarMark(
                        x: .value("Amount", item.amount),
                        y: .value("Category", item.category.title)
                    )
                    .foregroundStyle(item.category.tint.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .frame(height: 240)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var recentTransactionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent Activity")
                .font(.headline)

            ForEach(appContext.monthlySummary.recentTransactions) { transaction in
                TransactionRow(transaction: transaction)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI Insight of the Day", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
            }

            switch appContext.insightState {
            case .idle, .loading:
                ProgressView("Preparing insight...")
            case .available(let cards):
                Text(cards.first(where: { $0.kind == .budgeting })?.body ?? "No insight available.")
                    .foregroundStyle(AppTheme.ink)
            case .unavailable(let message), .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AppTheme.primary.opacity(0.95), AppTheme.secondary.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .foregroundStyle(Color.white)
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.mutedInk)
            Text(value)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.75), in: Capsule())
    }
}

private struct TransactionRow: View {
    let transaction: TransactionRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transaction.category.symbolName)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(transaction.category.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.category.title)
                    .font(.subheadline.weight(.semibold))
                Text(transaction.note.isEmpty ? "No note" : transaction.note)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(CurrencyFormatter.pesoString(from: transaction.amount))
                    .font(.subheadline.weight(.semibold))
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
    }
}
