import Foundation
import SwiftData

/// Schema V5 — adds the "Ask FinSight" chat transcript.
///
/// Every V4 model is unchanged and reused as-is, so V4 → V5 is a lightweight migration that only
/// adds the `ChatMessageRecord` table. CloudKit-compatible like V2-V4: defaults everywhere, no
/// `.unique` (duplicate ids are removed by `StoreIntegrity`). The transcript stays on this device.
enum FinSightSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] {
        FinSightSchemaV4.models + [ChatMessageRecord.self]
    }

    /// One message in the assistant chat, from the user or from FinSight.
    @Model
    final class ChatMessageRecord {
        var id: UUID = UUID()
        var roleRawValue: String = ChatRole.user.rawValue
        var text: String = ""
        /// How an assistant reply was produced; `nil` for the user's own messages.
        var replyKindRawValue: String?
        var createdAt: Date = Date.now

        init(id: UUID = UUID(), role: ChatRole, text: String, replyKind: ChatReplyKind? = nil, createdAt: Date = .now) {
            self.id = id
            self.roleRawValue = role.rawValue
            self.text = text
            self.replyKindRawValue = replyKind?.rawValue
            self.createdAt = createdAt
        }

        var role: ChatRole { ChatRole(rawValue: roleRawValue) ?? .user }
        var replyKind: ChatReplyKind? { replyKindRawValue.flatMap(ChatReplyKind.init(rawValue:)) }
    }
}
