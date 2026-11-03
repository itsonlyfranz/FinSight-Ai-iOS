import SwiftUI

struct TransactionEditorView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
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
                    Section("Category") {
                        Picker("Category", selection: Bindable(appContext).activeDraft.category) {
                            ForEach(SpendingCategory.allCases) { category in
                                Label(category.title, systemImage: category.symbolName)
                                    .tag(category)
                            }
                        }
                    }
                }

                Section("Details") {
                    TextField(appContext.activeDraft.kind == .income ? "Source" : "Merchant", text: Bindable(appContext).activeDraft.merchantName)
                        .textInputAutocapitalization(.words)
                    DatePicker("Date", selection: Bindable(appContext).activeDraft.date, displayedComponents: .date)
                    TextField("Note", text: Bindable(appContext).activeDraft.note, axis: .vertical)
                        .lineLimit(2...4)
                }
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
    }
}
