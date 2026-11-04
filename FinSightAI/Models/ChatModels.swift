import Foundation

/// Who wrote a chat message.
enum ChatRole: String, Sendable, Equatable {
    case user
    case assistant
}

/// How an assistant reply was produced, so the chat can label it honestly.
enum ChatReplyKind: String, Sendable, Equatable, CaseIterable {
    /// Written by the on-device model, with every amount checked against the user's data.
    case answer
    /// Worked out by code from the user's data (the FAQ fallback), no model involved.
    case quickAnswer
    /// The app's own scope check declined the question (investment picks, tax or legal advice…).
    case guardrail
    /// The on-device model declined, or Apple's safety checks blocked the request.
    case refusal

    /// Whether the reply gives money guidance, and so carries the "not financial advice" note.
    var carriesDisclaimer: Bool {
        switch self {
        case .answer, .quickAnswer: true
        case .guardrail, .refusal: false
        }
    }
}

/// A chat message as the interface and the assistant see it.
struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    let text: String
    let replyKind: ChatReplyKind?
    let createdAt: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, replyKind: ChatReplyKind? = nil, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.replyKind = replyKind
        self.createdAt = createdAt
    }

    init(_ record: ChatMessageRecord) {
        self.init(id: record.id, role: record.role, text: record.text, replyKind: record.replyKind, createdAt: record.createdAt)
    }
}
