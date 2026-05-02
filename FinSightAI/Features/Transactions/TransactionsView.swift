import SwiftUI

struct TransactionsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var showingEditor = false
    @State private var showingRecurringEditor = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Recurring") {
                    NavigationLink {
                        RecurringTransactionsView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "repeat.circle.fill")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recurring Charges")
                                    .font(.headline)
                                Text("\(appContext.recurringSummary.itemCount) set - \(CurrencyFormatter.pesoString(from: appContext.recurringSummary.totalMonthlySpend))/mo")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                ForEach(appContext.sections) { section in
                    Section(section.title) {
                        ForEach(section.transactions) { transaction in
                            TransactionListRow(transaction: transaction)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) {
                                        do {
                                            try appContext.delete(transaction)
                                        } catch {
                                            errorMessage = error.localizedDescription
                                        }
                                    }

                                    Button("Edit") {
                                        appContext.prepareEdit(for: transaction)
                                        showingEditor = true
                                    }
                                    .tint(AppTheme.secondary)

                                    Button("Make recurring") {
                                        appContext.prepareRecurringExpense(from: transaction)
                                        showingRecurringEditor = true
                                    }
                                    .tint(AppTheme.primary)
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appContext.prepareNewTransaction()
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                TransactionEditorView(
                    onSave: {
                        do {
                            try appContext.saveDraft()
                            showingEditor = false
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                )
                .environment(appContext)
            }
            .sheet(isPresented: $showingRecurringEditor) {
                RecurringExpenseEditorView(
                    onSave: {
                        do {
                            try appContext.saveRecurringDraft()
                            showingRecurringEditor = false
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                )
                .environment(appContext)
            }
            .alert("Unable to save", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct TransactionListRow: View {
    let transaction: TransactionRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transaction.category.symbolName)
                .font(.headline)
                .foregroundStyle(transaction.category.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchantName.isEmpty ? transaction.category.title : transaction.merchantName)
                    .font(.headline)
                Text(transaction.note.isEmpty ? "Quick expense log" : transaction.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(CurrencyFormatter.pesoString(from: transaction.amount))
                    .font(.headline)
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct RecurringTransactionsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var showingEditor = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if appContext.recurringSummary.items.isEmpty {
                FinSightEmptyState(
                    title: "No recurring charges set",
                    systemImage: "repeat.circle",
                    message: "Add rent, subscriptions, utilities, or bills you want FinSight AI to track."
                )
                .listRowBackground(Color.clear)
            } else {
                Section("Active") {
                    ForEach(appContext.recurringSummary.items) { item in
                        RecurringTransactionRow(item: item)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    do {
                                        if let record = appContext.recurringExpenses.first(where: { $0.id == item.id }) {
                                            try appContext.delete(record)
                                        }
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }

                                Button("Edit") {
                                    if let record = appContext.recurringExpenses.first(where: { $0.id == item.id }) {
                                        appContext.prepareEdit(for: record)
                                        showingEditor = true
                                    }
                                }
                                .tint(AppTheme.secondary)
                            }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Recurring")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appContext.prepareNewRecurringExpense()
                    showingEditor = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            RecurringExpenseEditorView(
                onSave: {
                    do {
                        try appContext.saveRecurringDraft()
                        showingEditor = false
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            )
            .environment(appContext)
        }
        .alert("Unable to save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct RecurringTransactionRow: View {
    let item: RecurringTransaction

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.status.systemImage)
                .font(.headline)
                .foregroundStyle(statusTint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.merchantName)
                    .font(.headline)
                Text("\(item.status.title) - expected day \(item.expectedDay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(CurrencyFormatter.pesoString(from: item.monthlyAmount))
                    .font(.headline)
                    .monospacedDigit()
                Text("per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private var statusTint: Color {
        switch item.status {
        case .missed: .red
        case .due: .orange
        case .upcoming: .blue
        }
    }
}

private struct RecurringExpenseEditorView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Merchant") {
                    TextField("Merchant", text: Bindable(appContext).activeRecurringDraft.merchantName)
                        .textInputAutocapitalization(.words)
                    if let error = appContext.activeRecurringDraft.validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Amount") {
                    TextField("0.00", text: Bindable(appContext).activeRecurringDraft.amountText)
                        .keyboardType(.decimalPad)
                }

                Section("Schedule") {
                    Stepper(
                        "Expected day \(appContext.activeRecurringDraft.expectedDay)",
                        value: Bindable(appContext).activeRecurringDraft.expectedDay,
                        in: 1...31
                    )
                    Toggle("Active", isOn: Bindable(appContext).activeRecurringDraft.isActive)
                }

                Section("Category") {
                    Picker("Category", selection: Bindable(appContext).activeRecurringDraft.category) {
                        ForEach(SpendingCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbolName)
                                .tag(category)
                        }
                    }
                }

                Section("Details") {
                    TextField("Note", text: Bindable(appContext).activeRecurringDraft.note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle(appContext.editingRecurringExpense == nil ? "New Recurring" : "Edit Recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(appContext.activeRecurringDraft.validationError != nil)
                }
            }
        }
    }
}
