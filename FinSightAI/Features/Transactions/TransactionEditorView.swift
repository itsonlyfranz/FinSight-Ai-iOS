import SwiftUI

struct TransactionEditorView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void
    @State private var quickAddText = ""
    @State private var isReadingQuickAdd = false
    @State private var quickAddMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if appContext.editingTransaction == nil {
                    quickAddSection
                }

                Section {
                    Picker("Type", selection: Bindable(appContext).activeDraft.kind) {
                        ForEach(TransactionKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Transaction type")
                } footer: {
                    if appContext.activeDraft.kind == .income {
                        Text("For one-off income. Regular income, like a salary, is set up under Settings › Income.")
                    }
                }

                Section("Amount") {
                    TextField("0.00", text: Bindable(appContext).activeDraft.amountText)
                        .keyboardType(.decimalPad)
                    if let error = appContext.activeDraft.validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if appContext.activeDraft.kind != .income {
                    Section {
                        Picker("Category", selection: categoryBinding) {
                            ForEach(SpendingCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbolName)
                                    .tag(category)
                            }
                        }
                    } header: {
                        Text("Category")
                    } footer: {
                        if let suggestion = appContext.categorySuggestion, !appContext.activeDraft.categoryIsUserChosen || suggestion.category == appContext.activeDraft.category {
                            Label(
                                suggestion.source == .model ? "Suggested by on-device AI" : "Suggested from the merchant name",
                                systemImage: "sparkles"
                            )
                        }
                    }
                }

                Section("Details") {
                    TextField(appContext.activeDraft.kind == .income ? "Source" : "Merchant", text: Bindable(appContext).activeDraft.merchantName)
                        .textInputAutocapitalization(.words)
                        .onSubmit { appContext.normalizeActiveMerchant() }
                    DatePicker("Date", selection: Bindable(appContext).activeDraft.date, displayedComponents: .date)
                    TextField("Note", text: Bindable(appContext).activeDraft.note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .task(id: appContext.activeDraft.merchantName) {
                // Wait for a pause in typing, then suggest a category for what was typed.
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                await appContext.suggestCategoryForActiveDraft()
            }
            .navigationTitle(appContext.editingTransaction == nil ? "New Transaction" : "Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(appContext.activeDraft.validationError != nil)
                }
            }
        }
        .onAppear { appContext.isTransactionEditorOpen = true }
        .onDisappear { appContext.isTransactionEditorOpen = false }
    }

    /// Choosing a category by hand stops automatic suggestions from changing it.
    private var categoryBinding: Binding<SpendingCategory> {
        Binding(
            get: { appContext.activeDraft.category },
            set: {
                appContext.activeDraft.category = $0
                appContext.activeDraft.categoryIsUserChosen = true
            }
        )
    }

    private var quickAddSection: some View {
        Section {
            HStack {
                TextField("e.g. coffee 150 yesterday", text: $quickAddText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(readQuickAdd)
                if isReadingQuickAdd {
                    ProgressView()
                } else {
                    Button("Fill", action: readQuickAdd)
                        .disabled(quickAddText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } header: {
            Text("Quick add")
        } footer: {
            Text(quickAddMessage ?? "Type what you spent in your own words. The amount and date are read exactly as typed; check the details below before saving.")
        }
    }

    private func readQuickAdd() {
        let text = quickAddText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !isReadingQuickAdd else { return }
        isReadingQuickAdd = true
        quickAddMessage = nil
        Task {
            let foundAmount = await appContext.applyQuickAdd(text)
            isReadingQuickAdd = false
            if foundAmount {
                quickAddText = ""
            } else {
                quickAddMessage = "Couldn't find an amount. Add one like \"coffee 150\", or fill in the fields below."
            }
        }
    }
}
