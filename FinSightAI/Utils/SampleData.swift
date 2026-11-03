import Foundation

enum SampleData {
    /// Builds fresh demo records relative to `now`. Fresh instances each call, so a record is
    /// never inserted into two contexts.
    static func makeTransactions(now: Date = .now) -> [TransactionRecord] {
        func day(_ days: Double) -> Date { now.addingTimeInterval(-86_400 * days) }
        return [
            TransactionRecord(amount: 2800, merchantName: "Landers", category: .groceries, date: day(2), note: "Weekly restock"),
            TransactionRecord(amount: 450, merchantName: "Grab", category: .transport, date: day(3), note: "Ride share"),
            TransactionRecord(amount: 1690, merchantName: "Wildflour", category: .dining, date: day(4), note: "Team dinner"),
            TransactionRecord(amount: 3200, merchantName: "Meralco", category: .bills, date: day(8), note: "Electric bill"),
            TransactionRecord(amount: 3150, merchantName: "Meralco", category: .bills, date: day(38), note: "Electric bill"),
            TransactionRecord(amount: 3300, merchantName: "Meralco", category: .bills, date: day(68), note: "Electric bill"),
            TransactionRecord(amount: 980, merchantName: "Shopee", category: .shopping, date: day(10), note: "Household items"),
            TransactionRecord(amount: 2500, merchantName: "BPI", category: .savings, date: day(12), note: "Emergency fund"),
            TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: day(14), note: "Streaming"),
            TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: day(44), note: "Streaming"),
            TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: day(74), note: "Streaming"),
            TransactionRecord(amount: 2100, merchantName: "Salcedo Market", category: .groceries, date: day(18), note: "Fresh market"),
            TransactionRecord(amount: 1250, merchantName: "Watsons", category: .health, date: day(20), note: "Pharmacy"),
            TransactionRecord(amount: 5200, merchantName: "Victory Liner", category: .travel, date: day(25), note: "Bus and hotel deposit")
        ]
    }
}
