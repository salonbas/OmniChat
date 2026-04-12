// Message.swift
// OmniChat
// SwiftData 訊息模型

import Foundation
import SwiftData

@Model
final class Message {
    var id: UUID = UUID()
    var role: String = "user"
    var content: String = ""
    var model: String?
    var createdAt: Date = Date()
    var conversation: Conversation?

    init(role: String, content: String, model: String? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.model = model
        self.createdAt = Date()
    }
}
