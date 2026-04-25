import SwiftUI

struct SimulatorView: View {
    @Environment(AppContext.self) private var appContext
    @State private var dailySavings: Double = 100
    @State private var reductionPercent: Double = 15
    @State private var savingsGoal: Double = 50_000

    var body: some View {
        let input = SimulationInput(
            currentMonthlySpending: appContext.monthlySummary.totalSpent,
            dailySavings: dailySavings,
            reductionPercent: reductionPercent,
            savingsGoal: savingsGoal
        )
        let projection = appContext.simulationService.project(input: input)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    heroCard(input: input, projection: projection)
                    controlsCard
                    projectionCard(projection: projection)
                    explanationCard(input: input)
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("What If")
        }
        .task(id: AIFingerprint.simulation(input: input, projection: projection)) {
            await appContext.loadSimulationExplanation(input: input)
        }
    }

    private func heroCard(input: SimulationInput, projection: SimulationProjection) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Scenario Builder")
                .font(.headline)
                .foregroundStyle(AppTheme.surface.opacity(0.85))
            Text(CurrencyFormatter.pesoString(from: projection.monthlySavings))
                .font(AppTheme.Typography.heroValue)
                .foregroundStyle(AppTheme.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: projection.monthlySavings)
            Text("Projected monthly savings if you set aside \(CurrencyFormatter.pesoString(from: input.dailySavings)) a day and trim \(Int(input.reductionPercent))% of current spending.")
                .foregroundStyle(AppTheme.surface.opacity(0.88))
        }
        .finSightCard(surface: AppTheme.surfaceElevated)
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Daily savings")
                    .font(.headline)
                Text(CurrencyFormatter.pesoString(from: dailySavings))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.3), value: dailySavings)
                Slider(value: $dailySavings, in: 0...500, step: 10)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Spending reduction")
                    .font(.headline)
                Text("\(Int(reductionPercent))%")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.3), value: reductionPercent)
                Slider(value: $reductionPercent, in: 0...50, step: 1)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Savings goal")
                    .font(.headline)
                Text(CurrencyFormatter.pesoString(from: savingsGoal))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.3), value: savingsGoal)
                Slider(value: $savingsGoal, in: 5_000...200_000, step: 1_000)
            }
        }
        .finSightCard()
    }

    private func projectionCard(projection: SimulationProjection) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Projected savings")
                .font(.headline)

            projectionRow(label: "3 months", value: projection.projectedSavingsThreeMonths)
            Divider().overlay(AppTheme.divider)
            projectionRow(label: "6 months", value: projection.projectedSavingsSixMonths)
            Divider().overlay(AppTheme.divider)
            projectionRow(label: "12 months", value: projection.projectedSavingsTwelveMonths)

            if let months = projection.monthsToGoal {
                Divider().overlay(AppTheme.divider)
                HStack {
                    Text("Time to goal")
                    Spacer()
                    Text("\(months) months")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.3), value: months)
                }
            }
        }
        .finSightCard()
    }

    private func explanationCard(input: SimulationInput) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Label("AI Explanation", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                FinSightStreamingRefreshControl(
                    isRefreshing: appContext.isSimulationRefreshInFlight || simulatorExplanationIsRefreshing,
                    action: {
                    Task {
                        await appContext.loadSimulationExplanation(input: input, forceRefresh: true)
                    }
                },
                    progressText: "Streaming...",
                    buttonStyleKind: .bordered
                )
            }

            switch appContext.simulatorExplanationState {
            case .idle, .loading:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    FinSightTypingIndicator()
                    Text("Preparing scenario explanation...")
                        .foregroundStyle(AppTheme.mutedInk)
                }
            case .available(let content):
                if content.isRefreshing {
                    FinSightStatusLine(text: "Streaming latest explanation...")
                }
                FinSightMarkdownView(markdown: content.value, style: .simulatorExplanation)
                FinSightStatusLine(text: RelativeTimestampFormatter.updatedString(for: content.lastUpdated))
                if let statusMessage = content.statusMessage {
                    Text(statusMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
            case .unavailable(let message), .failure(let message):
                Text(message)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
    }

    private var simulatorExplanationIsRefreshing: Bool {
        if case .available(let content) = appContext.simulatorExplanationState {
            return content.isRefreshing
        }
        return false
    }

    private func projectionRow(label: String, value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(CurrencyFormatter.pesoString(from: value))
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.3), value: value)
        }
    }
}
