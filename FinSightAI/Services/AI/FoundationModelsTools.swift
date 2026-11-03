#if canImport(FoundationModels)
import FoundationModels

/// The tools the model can call so every number it quotes comes from code. Each one reads the same
/// `LedgerSnapshot` the grounding prompt was built from and returns plain text.
enum LedgerTools {
    static func all(for ledger: LedgerSnapshot, log: ToolOutputLog? = nil) -> [any Tool] {
        [
            CategoryTotalsTool(ledger: ledger, log: log),
            TransactionSearchTool(ledger: ledger, log: log),
            BudgetStatusTool(ledger: ledger, log: log)
        ]
    }
}

private extension Tool {
    func recordOutput(_ output: String, in log: ToolOutputLog?) -> String {
        log?.record(output) ?? output
    }
}

struct CategoryTotalsTool: Tool {
    let ledger: LedgerSnapshot
    var log: ToolOutputLog?
    let name = "categoryTotals"
    var description: String {
        "Total spending per category for one month. The current month is \(LedgerText.monthLabel(ledger, monthsAgo: 0)). "
            + "Use it for any category amount that isn't in the facts."
    }

    @Generable
    struct Arguments {
        @Guide(description: "Months before the current month: 0 is the current month, 1 is the month before it, and so on up to 11.", .range(0...11))
        var monthsAgo: Int
        @Guide(description: "Only this category. Leave out for every category.")
        var category: SpendingCategoryChoice?
    }

    func call(arguments: Arguments) async throws -> String {
        recordOutput(LedgerText.categoryTotals(ledger, monthsAgo: arguments.monthsAgo, category: arguments.category?.category), in: log)
    }
}

struct TransactionSearchTool: Tool {
    let ledger: LedgerSnapshot
    var log: ToolOutputLog?
    let name = "transactions"
    let description = "Finds the user's transactions whose merchant matches some text, newest first."

    @Generable
    struct Arguments {
        @Guide(description: "Merchant name or part of it, e.g. 'uber'.")
        var matching: String
        @Guide(description: "How many results to return.", .range(1...8))
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> String {
        recordOutput(LedgerText.transactions(ledger, matching: arguments.matching, limit: arguments.limit), in: log)
    }
}

struct BudgetStatusTool: Tool {
    let ledger: LedgerSnapshot
    var log: ToolOutputLog?
    let name = "budgetStatus"
    let description = "This month's spending against each category budget: spent, limit and amount left or over."

    @Generable
    struct Arguments {
        @Guide(description: "Only this category. Leave out for every budget.")
        var category: SpendingCategoryChoice?
    }

    func call(arguments: Arguments) async throws -> String {
        recordOutput(LedgerText.budgetStatus(ledger, category: arguments.category?.category), in: log)
    }
}
#endif
