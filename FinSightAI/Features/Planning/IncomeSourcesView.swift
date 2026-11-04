import SwiftUI

/// Recurring monthly income (salary, allowance, …).
struct IncomeSourcesView: View {
    @Environment(AppContext.self) private var appContext
    @State private var editorTarget: IncomeEditorTarget?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if appContext.incomeSources.isEmpty {
                    FinSightEmptyState(
                        title: "No income yet",
                        systemImage: "banknote",
                        message: "Add your salary or other regular income to see how much of it you spend each month."
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(appContext.incomeSources) { source in
                    HStack {
                        Button {
                            editorTarget = IncomeEditorTarget(source: source)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name).font(.headline)
                                Text("\(CurrencyFormatter.string(from: source.monthlyAmount)) per month")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppTheme.mutedInk)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Toggle("Counts toward income", isOn: Binding(
                            get: { source.isActive },
                            set: { value in run { try appContext.setIncomeSource(source, active: value) } }
                        ))
                        .labelsHidden()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(source.name), \(CurrencyFormatter.string(from: source.monthlyAmount)) per month, \(source.isActive ? String(localized: "active") : String(localized: "paused"))")
                    .accessibilityHint("Double tap to edit")
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            run { try appContext.delete(source) }
                        }
                    }
                }
            } footer: {
                Text("Total: \(CurrencyFormatter.string(from: appContext.monthlyRecurringIncome)) per month. One-off income such as a bonus can be logged as an Income transaction and counts toward the month it's dated in.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Income")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorTarget = IncomeEditorTarget(source: nil)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3)
                }
                .accessibilityLabel("Add income")
            }
        }
        .sheet(item: $editorTarget) { target in
            IncomeSourceEditor(source: target.source)
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

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

private struct IncomeEditorTarget: Identifiable {
    let id = UUID()
    let source: IncomeSource?
}

private struct IncomeSourceEditor: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let source: IncomeSource?
    @State private var name = ""
    @State private var amountText = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Salary", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityLabel("Income name")
                }
                Section("Monthly amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Monthly income amount")
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(source == nil ? Text("New Income") : Text("Edit Income"))
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
                if let source {
                    name = source.name
                    amountText = CurrencyFormatter.plainNumberString(from: source.monthlyAmount)
                }
            }
        }
    }

    private func save() {
        do {
            try appContext.saveIncomeSource(source, name: name, monthlyAmount: amountText.parsedAmount)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
