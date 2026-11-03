import SwiftUI

/// Savings goals with progress, months-to-reach and a "funded by" estimate.
struct SavingsGoalsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var editorTarget: GoalEditorTarget?
    @State private var contributionGoal: SavingsGoal?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if appContext.savingsGoals.isEmpty {
                FinSightEmptyState(
                    title: "No goals yet",
                    systemImage: "flag.checkered",
                    message: "Create a goal to track your progress and see when it will be funded."
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(appContext.savingsGoals) { goal in
                        SavingsGoalRow(goal: goal, projection: appContext.goalProjection(for: goal))
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    do { try appContext.delete(goal) } catch { errorMessage = error.localizedDescription }
                                }
                                Button("Edit") { editorTarget = GoalEditorTarget(goal: goal) }
                                    .tint(AppTheme.secondary)
                                Button("Add money") { contributionGoal = goal }
                                    .tint(AppTheme.primary)
                            }
                            .accessibilityAction(named: "Add money") { contributionGoal = goal }
                            .accessibilityAction(named: "Edit") { editorTarget = GoalEditorTarget(goal: goal) }
                    }
                } footer: {
                    Text(paceFootnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Savings Goals")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = GoalEditorTarget(goal: nil)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .accessibilityLabel("Add goal")
            }
        }
        .sheet(item: $editorTarget) { target in
            GoalEditor(goal: target.goal)
        }
        .sheet(item: $contributionGoal) { goal in
            ContributionSheet(goal: goal)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var paceFootnote: String {
        let share = appContext.goalSurplusShare
        if share > 0 {
            return "Goals without recent contributions are estimated from your monthly income minus spending, shared across unfinished goals (about \(CurrencyFormatter.string(from: share)) a month each)."
        }
        return "Goals are estimated from your recent contributions, or from your monthly income minus spending once you've added income."
    }
}

private struct GoalEditorTarget: Identifiable {
    let id = UUID()
    let goal: SavingsGoal?
}

private struct GoalEditor: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal?
    @State private var name = ""
    @State private var targetText = ""
    @State private var savedText = ""
    @State private var hasTargetDate = false
    @State private var targetDate = Calendar.current.date(byAdding: .month, value: 12, to: .now) ?? .now
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("Name (e.g. Emergency fund)", text: $name)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel("Goal name")
                    TextField("Target amount", text: $targetText)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Target amount")
                    if goal == nil {
                        TextField("Already saved (optional)", text: $savedText)
                            .keyboardType(.decimalPad)
                            .accessibilityLabel("Amount already saved")
                    }
                }
                Section {
                    Toggle("Target date", isOn: $hasTargetDate)
                    if hasTargetDate {
                        DatePicker("Reach by", selection: $targetDate, in: Date.now..., displayedComponents: .date)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                }
            }
            .onAppear {
                if let goal {
                    name = goal.name
                    targetText = CurrencyFormatter.plainNumberString(from: goal.targetAmount)
                    if let date = goal.targetDate {
                        hasTargetDate = true
                        targetDate = date
                    }
                }
            }
        }
    }

    private func save() {
        do {
            let saved = savedText.trimmingCharacters(in: .whitespaces).isEmpty ? Decimal(0) : savedText.parsedAmount
            guard let saved else { throw PlanningError.invalidAmount }
            try appContext.saveGoal(
                goal,
                name: name,
                targetAmount: targetText.parsedAmount,
                savedAmount: saved,
                targetDate: hasTargetDate ? targetDate : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ContributionSheet: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let goal: SavingsGoal
    @State private var amountText = ""
    @State private var isWithdrawal = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isWithdrawal) {
                        Text("Deposit").tag(false)
                        Text("Withdraw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Amount")
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                } footer: {
                    Text("\(goal.name) has \(CurrencyFormatter.string(from: goal.savedAmount)) of \(CurrencyFormatter.string(from: goal.targetAmount)).")
                }
            }
            .navigationTitle("Update \(goal.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        do {
                            try appContext.contribute(to: goal, amount: amountText.parsedAmount, withdraw: isWithdrawal)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
