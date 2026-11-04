import Foundation

extension AppContext {
    var systemRefreshToken: String {
        transactions.map { "\($0.id):\($0.updatedAt)" }.joined() +
        budgets.map { "\($0.id):\($0.updatedAt)" }.joined() +
        recurringExpenses.map { "\($0.id):\($0.updatedAt)" }.joined() +
        engineInsights.map(\.id).joined() + currencyCode
    }
}
