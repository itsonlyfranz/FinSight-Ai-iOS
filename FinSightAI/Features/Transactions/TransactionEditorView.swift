import SwiftUI

struct TransactionEditorView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    TextField("0.00", text: Bindable(appContext).activeDraft.amountText)
                        .keyboardType(.decimalPad)
                    if let error = appContext.activeDraft.validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("Category") {
                    Picker("Category", selection: Bindable(appContext).activeDraft.category) {
                        ForEach(SpendingCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbolName)
                                .tag(category)
                        }
                    }
                }

                Section("Details") {
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
