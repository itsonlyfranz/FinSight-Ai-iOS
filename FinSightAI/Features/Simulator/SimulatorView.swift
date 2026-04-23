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
                VStack(alignment: .leading, spacing: 20) {
                    heroCard(input: input, projection: projection)
                    controlsCard
                    projectionCard(projection: projection)
                    explanationCard(input: input)
                }
                .padding(20)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("What If")
        }
        .task(id: taskID(for: input)) {
            await appContext.loadSimulationExplanation(input: input)
        }
    }

    private func heroCard(input: SimulationInput, projection: SimulationProjection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scenario Builder")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            Text(CurrencyFormatter.pesoString(from: projection.monthlySavings))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Projected monthly savings if you set aside \(CurrencyFormatter.pesoString(from: input.dailySavings)) a day and trim \(Int(input.reductionPercent))% of current spending.")
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [AppTheme.secondary, AppTheme.primary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Daily savings")
                    .font(.headline)
                Text(CurrencyFormatter.pesoString(from: dailySavings))
                    .font(.title3.weight(.semibold))
                Slider(value: $dailySavings, in: 0...500, step: 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Spending reduction")
                    .font(.headline)
                Text("\(Int(reductionPercent))%")
                    .font(.title3.weight(.semibold))
                Slider(value: $reductionPercent, in: 0...50, step: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Savings goal")
                    .font(.headline)
                Text(CurrencyFormatter.pesoString(from: savingsGoal))
                    .font(.title3.weight(.semibold))
                Slider(value: $savingsGoal, in: 5_000...200_000, step: 1_000)
            }
        }
        .padding(22)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func projectionCard(projection: SimulationProjection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Projected savings")
                .font(.headline)

            projectionRow(label: "3 months", value: projection.projectedSavingsThreeMonths)
            projectionRow(label: "6 months", value: projection.projectedSavingsSixMonths)
            projectionRow(label: "12 months", value: projection.projectedSavingsTwelveMonths)

            if let months = projection.monthsToGoal {
                HStack {
                    Text("Time to goal")
                    Spacer()
                    Text("\(months) months")
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(22)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func explanationCard(input: SimulationInput) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI Explanation", systemImage: "sparkles")
                .font(.headline)

            switch appContext.simulatorExplanationState {
            case .idle, .loading:
                ProgressView("Preparing scenario explanation...")
            case .loaded(let explanation):
                Text(explanation)
                    .foregroundStyle(AppTheme.mutedInk)
            case .unavailable(let message), .failure(let message):
                Text(message)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .padding(22)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func projectionRow(label: String, value: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(CurrencyFormatter.pesoString(from: value))
                .fontWeight(.semibold)
        }
    }

    private func taskID(for input: SimulationInput) -> String {
        "\(input.currentMonthlySpending)-\(input.dailySavings)-\(input.reductionPercent)-\(input.savingsGoal)"
    }
}
