// Conversation.swift
// OmniChat
// SwiftData 對話模型

import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID = UUID()
    var title: String = "New Chat"
    var modeIndex: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "New Chat", modeIndex: Int = 0) {
        self.id = UUID()
        self.title = title
        self.modeIndex = modeIndex
        self.createdAt = Date()
        self.updatedAt = Date()
        self.messages = []
    }
}
