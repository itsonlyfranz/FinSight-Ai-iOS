import Foundation
import OSLog
import SwiftData

/// Ask FinSight: the chat transcript, stored on this device, and the assistant behind it.
extension AppContext {
    /// Oldest messages beyond this many are deleted, so the transcript can't grow without bound.
    static let chatMessageLimit = 200
    /// Longest question accepted, in characters.
    static let chatQuestionLimit = 500

    private static let chatLogger = Logger(subsystem: "com.finsightai.app", category: "Chat")

    var assistantMode: AssistantMode { assistantService.mode }

    /// What the assistant knows about the user's money right now.
    func assistantContext(now: Date = .now) -> AssistantContext {
        let calendar = settings?.calendar() ?? .current
        let ledger = LedgerSnapshot(
            now: now,
            calendar: calendar,
            entries: LedgerEntry.history(from: transactions, now: now, calendar: calendar),
            budgets: budgetProgress.map { BudgetLimit(category: $0.category, limit: $0.limit) }
        )
        let charges = recurringSummary.spendingItems.map {
            AssistantContext.RecurringCharge(
                merchant: $0.merchantName,
                category: $0.category,
                monthlyAmount: Decimal($0.monthlyAmount).rounded(scale: 2),
                expectedDate: $0.expectedDate,
                isUpcoming: $0.status == .upcoming
            )
        }
        return AssistantContext(
            ledger: ledger,
            summary: monthlySummary,
            insights: engineInsights,
            monthlyIncome: incomeGauge.income,
            recurringCharges: charges,
            goals: savingsGoals.map { AssistantContext.GoalLine(name: $0.name, saved: $0.savedAmount, target: $0.targetAmount) },
            profile: UserProfile.load()
        )
    }

    /// The prompts offered under the chat.
    var suggestedChatPrompts: [String] {
        AssistantSuggestions.prompts(for: assistantContext())
    }

    func reloadChat() throws {
        let descriptor = FetchDescriptor<ChatMessageRecord>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
        chatMessages = try modelContext.fetch(descriptor).map(ChatMessage.init)
    }

    /// Saves the question, asks the assistant and saves its reply. Returns the reply, or nil when
    /// there was nothing to send or another question is still being answered.
    @discardableResult
    func sendChatMessage(_ text: String, now: Date = .now) async -> AssistantReply? {
        let question = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.chatQuestionLimit))
        guard !question.isEmpty, !isAssistantResponding else { return nil }
        isAssistantResponding = true
        assistantPartialReply = nil
        defer {
            isAssistantResponding = false
            assistantPartialReply = nil
        }

        let history = chatMessages
        appendChatMessage(ChatMessage(role: .user, text: question, createdAt: now))
        let context = assistantContext(now: now)

        let reply: AssistantReply
        do {
            reply = try await assistantService.reply(to: question, history: history, context: context) { [weak self] partial in
                await MainActor.run { self?.assistantPartialReply = partial }
            }
        } catch {
            // Only cancellation reaches here; answer from code so the question isn't left hanging.
            reply = AssistantReply(text: AssistantFAQ.answer(to: question, context: context), kind: .quickAnswer)
        }
        // Keep the reply after the question even if the clock moved backwards in between.
        let replyDate = max(Date.now, now.addingTimeInterval(0.001))
        appendChatMessage(ChatMessage(role: .assistant, text: reply.text, replyKind: reply.kind, createdAt: replyDate))
        return reply
    }

    /// Deletes the whole transcript.
    func clearChat() throws {
        try modelContext.delete(model: ChatMessageRecord.self)
        try modelContext.save()
        chatMessages = []
    }

    private func appendChatMessage(_ message: ChatMessage) {
        modelContext.insert(ChatMessageRecord(id: message.id, role: message.role, text: message.text, replyKind: message.replyKind, createdAt: message.createdAt))
        chatMessages.append(message)
        do {
            try pruneChat()
            try modelContext.save()
        } catch {
            Self.chatLogger.error("Failed to save chat message: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pruneChat() throws {
        guard chatMessages.count > Self.chatMessageLimit else { return }
        let stale = chatMessages.prefix(chatMessages.count - Self.chatMessageLimit)
        let staleIDs = Set(stale.map(\.id))
        let records = try modelContext.fetch(FetchDescriptor<ChatMessageRecord>())
        for record in records where staleIDs.contains(record.id) {
            modelContext.delete(record)
        }
        chatMessages.removeFirst(stale.count)
    }
}

#if DEBUG
extension AppContext {
    /// Debug-only launch hook (`-FinSightChatDemo "Question one|Question two"`) that asks the listed
    /// questions on an empty transcript, so screenshots and checks can show real replies.
    func askDebugChatQuestionsIfRequested(defaults: UserDefaults = .standard) async {
        guard chatMessages.isEmpty, let script = defaults.string(forKey: "FinSightChatDemo") else { return }
        for question in script.split(separator: "|") {
            await sendChatMessage(String(question))
        }
    }
}
#endif
