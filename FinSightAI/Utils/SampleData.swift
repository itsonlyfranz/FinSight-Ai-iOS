import Foundation

enum SampleData {
    static let transactions: [TransactionRecord] = [
        TransactionRecord(amount: 2800, merchantName: "Landers", category: .groceries, date: .now.addingTimeInterval(-86_400 * 2), note: "Weekly restock"),
        TransactionRecord(amount: 450, merchantName: "Grab", category: .transport, date: .now.addingTimeInterval(-86_400 * 3), note: "Ride share"),
        TransactionRecord(amount: 1690, merchantName: "Wildflour", category: .dining, date: .now.addingTimeInterval(-86_400 * 4), note: "Team dinner"),
        TransactionRecord(amount: 3200, merchantName: "Meralco", category: .bills, date: .now.addingTimeInterval(-86_400 * 8), note: "Electric bill"),
        TransactionRecord(amount: 3150, merchantName: "Meralco", category: .bills, date: .now.addingTimeInterval(-86_400 * 38), note: "Electric bill"),
        TransactionRecord(amount: 3300, merchantName: "Meralco", category: .bills, date: .now.addingTimeInterval(-86_400 * 68), note: "Electric bill"),
        TransactionRecord(amount: 980, merchantName: "Shopee", category: .shopping, date: .now.addingTimeInterval(-86_400 * 10), note: "Household items"),
        TransactionRecord(amount: 2500, merchantName: "BPI", category: .savings, date: .now.addingTimeInterval(-86_400 * 12), note: "Emergency fund"),
        TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: .now.addingTimeInterval(-86_400 * 14), note: "Streaming"),
        TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: .now.addingTimeInterval(-86_400 * 44), note: "Streaming"),
        TransactionRecord(amount: 720, merchantName: "Netflix", category: .entertainment, date: .now.addingTimeInterval(-86_400 * 74), note: "Streaming"),
        TransactionRecord(amount: 2100, merchantName: "Salcedo Market", category: .groceries, date: .now.addingTimeInterval(-86_400 * 18), note: "Fresh market"),
        TransactionRecord(amount: 1250, merchantName: "Watsons", category: .health, date: .now.addingTimeInterval(-86_400 * 20), note: "Pharmacy"),
        TransactionRecord(amount: 5200, merchantName: "Victory Liner", category: .travel, date: .now.addingTimeInterval(-86_400 * 25), note: "Bus and hotel deposit")
    ]
}
