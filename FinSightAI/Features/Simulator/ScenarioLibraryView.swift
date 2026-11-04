import Charts
import SwiftUI

/// Saved scenarios: save the one being edited, load or delete one, and pick up to three to compare.
struct ScenarioLibraryCard: View {
    @Environment(AppContext.self) private var appContext
    @State private var isNaming = false
    @State private var newName = ""
    @State private var comparedIDs: [UUID] = []
    @State private var showingComparison = false
    @State private var errorMessage: String?

    private var maximumSaved: Int { AppContext.maximumComparedScenarios - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Label("Saved scenarios", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Spacer()
                Button {
                    newName = ""
                    isNaming = true
                } label: {
                    Label("Save current", systemImage: "plus.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
            }

            if appContext.savedScenarios.isEmpty {
                Text("Save the scenario you're building to come back to it, or to compare it with another plan.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            } else {
                ForEach(appContext.savedScenarios) { record in
                    row(for: record)
                    if record.id != appContext.savedScenarios.last?.id {
                        Divider().overlay(AppTheme.divider)
                    }
                }
                Button {
                    showingComparison = true
                } label: {
                    Label("Compare with current", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .disabled(comparedIDs.isEmpty)
                Text("Pick up to \(maximumSaved) saved scenarios to compare against the one you're editing.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
        .alert("Save scenario", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Save") {
                do { try appContext.saveWorkingScenario(named: newName) } catch { errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saving under a name you already used updates that scenario.")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showingComparison) {
            ScenarioComparisonView(savedIDs: comparedIDs)
        }
        .onChange(of: appContext.savedScenarios.map(\.id)) { _, ids in
            comparedIDs.removeAll { !ids.contains($0) }
        }
    }

    private func row(for record: SavedScenarioRecord) -> some View {
        let isCompared = comparedIDs.contains(record.id)
        let result = record.scenario.map { appContext.simulate($0) }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Button {
                toggleComparison(record.id)
            } label: {
                Image(systemName: isCompared ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompared ? AppTheme.primary : AppTheme.mutedInk)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompared ? "Remove \(record.name) from comparison" : "Compare \(record.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.subheadline.weight(.semibold))
                if let result {
                    Text("\(CurrencyFormatter.string(from: result.monthlySavings))/mo · \(CurrencyFormatter.string(from: result.twelveMonths)) in 12 months")
                        .font(AppTheme.Typography.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.mutedInk)
                } else {
                    Text("This scenario can't be read.")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Menu {
                Button("Load", systemImage: "arrow.down.doc") { appContext.loadScenario(record) }
                    .disabled(result == nil)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    do { try appContext.deleteScenario(record) } catch { errorMessage = error.localizedDescription }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Actions for \(record.name)")
        }
    }

    private func toggleComparison(_ id: UUID) {
        if let index = comparedIDs.firstIndex(of: id) {
            comparedIDs.remove(at: index)
        } else if comparedIDs.count < maximumSaved {
            comparedIDs.append(id)
        }
    }
}

/// The current scenario and the chosen saved ones, as lines over 12 months and a table of figures.
struct ScenarioComparisonView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let savedIDs: [UUID]

    var body: some View {
        let comparison = appContext.scenarioComparison(including: savedIDs)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    chart(comparison)
                    table(comparison)
                    if let best = comparison.best {
                        Label("\(best.name) saves the most over 12 months.", systemImage: "trophy.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func chart(_ comparison: ScenarioComparison) -> some View {
        Chart {
            ForEach(comparison.rows) { row in
                ForEach(row.entry.result.timeline.filter { $0.month <= 12 }) { point in
                    LineMark(
                        x: .value("Month", point.month),
                        y: .value("Balance", point.balance.doubleValue),
                        series: .value("Scenario", row.entry.name)
                    )
                    .foregroundStyle(by: .value("Scenario", row.entry.name))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 3)) { value in
                AxisGridLine().foregroundStyle(AppTheme.divider)
                AxisValueLabel { if let month = value.as(Int.self) { Text("\(month)m") } }
            }
        }
        .frame(height: 220)
        .finSightCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Projected savings by scenario")
        .accessibilityValue(comparison.rows.map { "\($0.entry.name): \(CurrencyFormatter.string(from: $0.entry.result.twelveMonths)) after 12 months" }.joined(separator: ". "))
    }

    private func table(_ comparison: ScenarioComparison) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(comparison.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.entry.name).font(.headline)
                        if row.isBest { Image(systemName: "trophy.fill").foregroundStyle(AppTheme.primary).accessibilityLabel("Best") }
                        Spacer()
                        Text("\(CurrencyFormatter.string(from: row.entry.result.monthlySavings))/mo")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    HStack {
                        figure("3 mo", row.entry.result.threeMonths)
                        figure("6 mo", row.entry.result.sixMonths)
                        figure("12 mo", row.entry.result.twelveMonths)
                    }
                    if row.entry.id != comparison.rows.first?.entry.id {
                        let delta = row.twelveMonthDelta
                        Text("\(delta >= 0 ? "+" : "−")\(CurrencyFormatter.string(from: abs(delta))) vs Current after 12 months")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(delta >= 0 ? AppTheme.primary : .red)
                    }
                }
                .accessibilityElement(children: .combine)
                if row.id != comparison.rows.last?.id { Divider().overlay(AppTheme.divider) }
            }
        }
        .finSightCard()
    }

    private func figure(_ label: String, _ value: Decimal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(AppTheme.mutedInk)
            Text(CurrencyFormatter.string(from: value))
                .font(.caption.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
