import SwiftUI

struct TransactionsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var savedCount = 0
    @State private var showingEditor = false
    @State private var showingRecurringEditor = false
    @State private var errorMessage: String?
    @State private var filter = TransactionFilter()

    /// All months, or only the transactions matching the chips and search text.
    private var visibleSections: [TransactionMonthSection] {
        guard filter.isActive else { return appContext.sections }
        return DefaultSummaryService().monthlySections(from: filter.apply(to: appContext.transactions))
    }

    var body: some View {
        NavigationStack {
            List {
                if appContext.hasNoData {
                    SampleDataCard()
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                if !appContext.transactions.isEmpty {
                    CategoryFilterChips(filter: $filter)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                Section("Recurring") {
                    NavigationLink {
                        RecurringTransactionsView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "repeat.circle.fill")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primary)
                                .frame(minWidth: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recurring Charges")
                                    .font(.headline)
                                Text("\(appContext.recurringSummary.itemCount) set - \(CurrencyFormatter.string(from: appContext.recurringSummary.totalMonthlySpend))/mo")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                if filter.isActive, visibleSections.isEmpty {
                    ContentUnavailableView {
                        Label("No matching transactions", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different merchant name or clear the category filters.")
                    } actions: {
                        Button("Clear filters") { filter.reset() }
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(visibleSections) { section in
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
            .searchable(text: $filter.searchText, prompt: "Search merchants and notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appContext.prepareNewTransaction()
                        showingEditor = true
                    } label: {
                        Label("Add Expense", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
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
                            savedCount += 1
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
                            savedCount += 1
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                )
                .environment(appContext)
            }
            .sensoryFeedback(.success, trigger: savedCount)
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

private struct CategoryFilterChips: View {
    @Binding var filter: TransactionFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppTheme.Spacing.xs) {
                if filter.isActive {
                    Button {
                        filter.reset()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppTheme.surfaceAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear all filters")
                }
                ForEach(SpendingCategory.allCases) { category in
                    let isSelected = filter.categories.contains(category)
                    Button {
                        filter.toggle(category)
                    } label: {
                        Label(category.title, systemImage: category.symbolName)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(isSelected ? Color.white : AppTheme.ink)
                            .background(isSelected ? category.tint : AppTheme.surfaceAccent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(category.title) filter")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Category filters")
    }
}

private struct TransactionListRow: View {
    let transaction: TransactionRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: transaction.category.symbolName)
                .font(.headline)
                .foregroundStyle(transaction.category.tint)
                .frame(minWidth: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.merchantName.isEmpty ? transaction.category.title : transaction.merchantName)
                    .font(.headline)
                Text(transaction.note.isEmpty ? (transaction.kind == .income ? "Income" : "Quick expense log") : transaction.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(amountText)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(transaction.kind == .income ? Color.green : Color.primary)
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var amountText: String {
        let amount = CurrencyFormatter.string(from: transaction.amount)
        return transaction.kind == .income ? "+\(amount)" : amount
    }

    private var title: String {
        transaction.merchantName.isEmpty ? transaction.category.title : transaction.merchantName
    }

    private var accessibilityText: String {
        let kind = transaction.kind == .expense ? "" : "\(transaction.kind.title), "
        let date = transaction.date.formatted(date: .abbreviated, time: .omitted)
        return "\(kind)\(title), \(transaction.category.title), \(CurrencyFormatter.string(from: transaction.amount)), \(date)"
    }
}

private struct RecurringTransactionsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var showingEditor = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !appContext.recurringSummary.hasAnyItems {
                FinSightEmptyState(
                    title: "No recurring charges set",
                    systemImage: "repeat.circle",
                    message: "Add rent, subscriptions, utilities, or bills you want FinSight AI to track."
                )
                .listRowBackground(Color.clear)
            } else {
                if !appContext.recurringSummary.items.isEmpty {
                    Section("Active") {
                        ForEach(appContext.recurringSummary.items) { item in
                            RecurringTransactionRow(item: item)
                                .swipeActions(edge: .trailing) {
                                    recurringActions(for: item, activationTitle: "Pause", activate: false)
                                }
                        }
                    }
                }

                if !appContext.recurringSummary.inactiveItems.isEmpty {
                    Section {
                        ForEach(appContext.recurringSummary.inactiveItems) { item in
                            RecurringTransactionRow(item: item)
                                .swipeActions(edge: .trailing) {
                                    recurringActions(for: item, activationTitle: "Resume", activate: true)
                                }
                        }
                    } header: {
                        Text("Paused")
                    } footer: {
                        Text("Paused charges aren't counted in your totals. Swipe to resume or delete them.")
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

extension RecurringTransactionsView {
    @ViewBuilder
    fileprivate func recurringActions(for item: RecurringTransaction, activationTitle: String, activate: Bool) -> some View {
        Button("Delete", role: .destructive) {
            run(on: item) { try appContext.delete($0) }
        }

        Button("Edit") {
            if let record = appContext.recurringExpenses.first(where: { $0.id == item.id }) {
                appContext.prepareEdit(for: record)
                showingEditor = true
            }
        }
        .tint(AppTheme.secondary)

        Button(activationTitle) {
            run(on: item) { try appContext.setRecurringExpense($0, active: activate) }
        }
        .tint(activate ? AppTheme.primary : .orange)
    }

    fileprivate func run(on item: RecurringTransaction, _ action: (RecurringExpenseRecord) throws -> Void) {
        guard let record = appContext.recurringExpenses.first(where: { $0.id == item.id }) else { return }
        do {
            try action(record)
        } catch {
            errorMessage = error.localizedDescription
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
                .frame(minWidth: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.merchantName)
                    .font(.headline)
                Text("\(item.isActive ? item.status.title : "Paused") - expected day \(item.expectedDay)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(CurrencyFormatter.string(from: item.monthlyAmount))
                    .font(.headline)
                    .monospacedDigit()
                Text("per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .opacity(item.isActive ? 1 : 0.6)
        .accessibilityElement(children: .combine)
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
