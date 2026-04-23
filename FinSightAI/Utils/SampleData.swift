import Foundation

enum SampleData {
    static let transactions: [TransactionRecord] = [
        TransactionRecord(amount: 2800, category: .groceries, date: .now.addingTimeInterval(-86_400 * 2), note: "Weekly restock"),
        TransactionRecord(amount: 450, category: .transport, date: .now.addingTimeInterval(-86_400 * 3), note: "Ride share"),
        TransactionRecord(amount: 1690, category: .dining, date: .now.addingTimeInterval(-86_400 * 4), note: "Team dinner"),
        TransactionRecord(amount: 3200, category: .bills, date: .now.addingTimeInterval(-86_400 * 8), note: "Internet and utilities"),
        TransactionRecord(amount: 980, category: .shopping, date: .now.addingTimeInterval(-86_400 * 10), note: "Household items"),
        TransactionRecord(amount: 2500, category: .savings, date: .now.addingTimeInterval(-86_400 * 12), note: "Emergency fund"),
        TransactionRecord(amount: 720, category: .entertainment, date: .now.addingTimeInterval(-86_400 * 14), note: "Streaming and cinema"),
        TransactionRecord(amount: 2100, category: .groceries, date: .now.addingTimeInterval(-86_400 * 18), note: "Fresh market"),
        TransactionRecord(amount: 1250, category: .health, date: .now.addingTimeInterval(-86_400 * 20), note: "Pharmacy"),
        TransactionRecord(amount: 5200, category: .travel, date: .now.addingTimeInterval(-86_400 * 25), note: "Bus and hotel deposit")
    ]
}
