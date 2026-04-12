// ColorExtension.swift
// OmniChat
// hex 字串轉 SwiftUI Color

import SwiftUI

extension Color {
    /// 從 hex 字串建立 Color，例如 "#1e1e2e" 或 "1e1e2e"
    init?(hex: String?) {
        guard let hex = hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b)
    }
}

/// Theme 的便利存取，提供預設值
struct Theme {
    let config: AppConfig.ThemeConfig?

    var backgroundColor: Color { Color(hex: config?.backgroundColor) ?? Color(.windowBackgroundColor) }
    var backgroundOpacity: Double { config?.backgroundOpacity ?? 1.0 }
    var backgroundBlur: Double { config?.backgroundBlur ?? 0 }
    var sidebarColor: Color { Color(hex: config?.sidebarColor) ?? Color(.controlBackgroundColor) }
    var userBubbleColor: Color { Color(hex: config?.userBubbleColor) ?? Color.blue }
    var userTextColor: Color { Color(hex: config?.userTextColor) ?? Color.white }
    var assistantTextColor: Color { Color(hex: config?.assistantTextColor) ?? Color(.labelColor) }
    var inputBackgroundColor: Color { Color(hex: config?.inputBackgroundColor) ?? Color(.textBackgroundColor) }
    var inputTextColor: Color { Color(hex: config?.inputTextColor) ?? Color(.labelColor) }
    var accentColor: Color { Color(hex: config?.accentColor) ?? Color.accentColor }
}
