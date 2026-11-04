import SwiftUI

/// Per-category budget editor with progress for the current month.
struct BudgetsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var editingCategory: SpendingCategory?

    private var categories: [SpendingCategory] {
        SpendingCategory.allCases.filter(\.countsAsSpending)
    }

    var body: some View {
        List {
            if !appContext.budgetProgress.isEmpty {
                Section {
                    BudgetBarChart(items: appContext.budgetProgress)
                    HStack {
                        Text("Total")
                        Spacer()
                        Text("\(CurrencyFormatter.string(from: BudgetCalculator.totalSpent(appContext.budgetProgress))) of \(CurrencyFormatter.string(from: BudgetCalculator.totalLimit(appContext.budgetProgress)))")
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("This month")
                } footer: {
                    Text("Bars show spending; the dark tick marks each budget.")
                }
            }

            Section {
                ForEach(categories) { category in
                    Button {
                        editingCategory = category
                    } label: {
                        if let progress = appContext.progress(for: category) {
                            BudgetProgressRow(progress: progress)
                        } else {
                            HStack {
                                Label(category.localizedTitle, systemImage: category.symbolName)
                                    .foregroundStyle(AppTheme.ink)
                                Spacer()
                                Text("No budget")
                                    .foregroundStyle(AppTheme.mutedInk)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(category.localizedTitle), no budget set")
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Double tap to edit the budget")
                }
            } header: {
                Text("Monthly budgets")
            } footer: {
                Text("Savings transfers aren't counted as spending, so they don't have a budget.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Budgets")
        .sheet(item: $editingCategory) { category in
            BudgetEditor(category: category)
        }
    }
}

private struct BudgetEditor: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let category: SpendingCategory
    @State private var amountText = ""
    @State private var rollover = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Monthly limit for \(category.localizedTitle)") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("\(category.localizedTitle) monthly budget")
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle("Roll over unspent budget", isOn: $rollover)
                } footer: {
                    Text("Unspent budget from earlier months is added to this month's limit.")
                }
                if appContext.budget(for: category) != nil {
                    Section {
                        Button("Remove budget", role: .destructive) {
                            apply(amount: nil)
                        }
                    }
                }
            }
            .navigationTitle("\(category.localizedTitle) Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if amountText.trimmingCharacters(in: .whitespaces).isEmpty {
                            apply(amount: nil)
                        } else {
                            apply(amount: amountText.parsedAmount ?? -1)
                        }
                    }
                }
            }
            .onAppear {
                if let budget = appContext.budget(for: category) {
                    amountText = CurrencyFormatter.plainNumberString(from: budget.monthlyAmount)
                    rollover = budget.rolloverEnabled
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func apply(amount: Decimal?) {
        do {
            try appContext.setBudget(category: category, monthlyAmount: amount, rollover: rollover)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
