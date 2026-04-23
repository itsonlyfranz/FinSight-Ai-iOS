import SwiftUI

struct TransactionsView: View {
    @Environment(AppContext.self) private var appContext
    @State private var showingEditor = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
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
                Text(transaction.category.title)
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
