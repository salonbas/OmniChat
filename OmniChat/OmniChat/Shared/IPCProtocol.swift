// IPCProtocol.swift

// 定義 CLI ↔ App 之間的 IPC 通訊協議

import Foundation

// MARK: - CLI → App 請求

struct IPCRequest: Codable, Sendable {
    let action: Action
    let prompt: String?
    let model: String?
    let mode: Int?
    let silent: Bool
    let stdin: String?
    let conversationId: String?    // 指定對話 ID（-c 參數）
    let newConversation: Bool      // 是否建立新對話（--new 參數）

    enum Action: String, Codable, Sendable {
        case sendPrompt = "send_prompt"
        case toggle
        case newWindow = "new_window"
        case newConversation = "new_conversation"
        case clear
        case listModels = "list_models"
        case listModes = "list_modes"
        case history
    }

    init(
        action: Action,
        prompt: String? = nil,
        model: String? = nil,
        mode: Int? = nil,
        silent: Bool = false,
        stdin: String? = nil,
        conversationId: String? = nil,
        newConversation: Bool = false
    ) {
        self.action = action
        self.prompt = prompt
        self.model = model
        self.mode = mode
        self.silent = silent
        self.stdin = stdin
        self.conversationId = conversationId
        self.newConversation = newConversation
    }
}

// MARK: - App → CLI 回應

struct IPCResponse: Codable, Sendable {
    let status: Status
    let message: String?
    let chunk: String?
    let data: [String]?
    let modelUsed: String?
    let conversationId: String?    // 回傳對話 ID，讓 CLI 可以後續指定

    enum Status: String, Codable, Sendable {
        case ok
        case streaming
        case done
        case error
    }

    init(
        status: Status,
        message: String? = nil,
        chunk: String? = nil,
        data: [String]? = nil,
        modelUsed: String? = nil,
        conversationId: String? = nil
    ) {
        self.status = status
        self.message = message
        self.chunk = chunk
        self.data = data
        self.modelUsed = modelUsed
        self.conversationId = conversationId
    }
}

// MARK: - 外部腳本輸入格式

struct ProviderInput: Codable, Sendable {
    let messages: [ChatMessage]
    let model: String

    init(messages: [ChatMessage], model: String) {
        self.messages = messages
        self.model = model
    }
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

// MARK: - Config

struct AppConfig: Codable, Sendable {
    var defaultProvider: String
    var providers: [String: ProviderConfig]
    var modes: [ModeConfig]
    var defaultMode: Int
    var appearance: String
    var socketPath: String
    var hideAfterSend: Bool?
    var theme: ThemeConfig?
    var maxConcurrentModels: Int?  // 同時可跑幾個模型請求（預設 1）
    var hotkey: HotkeyConfig?

    struct ProviderConfig: Codable, Sendable {
        var command: String
        var defaultModel: String
        var models: [String]
    }

    struct ModeConfig: Codable, Sendable {
        var name: String
        var systemPrompt: String
    }

    struct ThemeConfig: Codable, Sendable {
        var backgroundColor: String?       // "#1e1e2e"
        var backgroundOpacity: Double?     // 0.0 ~ 1.0
        var backgroundBlur: Double?        // 0 ~ 100
        var sidebarColor: String?          // "#181825"
        var userBubbleColor: String?       // "#3b82f6"
        var userTextColor: String?         // "#ffffff"
        var assistantTextColor: String?    // "#cdd6f4"
        var inputBackgroundColor: String?  // "#313244"
        var inputTextColor: String?        // "#cdd6f4"
        var accentColor: String?           // "#89b4fa"
    }

    struct HotkeyConfig: Codable, Sendable {
        var doubleTapKey: String
        var doubleTapInterval: Int
        var longPressThreshold: Int
    }

    // MARK: 路徑

    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat")
    }

    static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    // MARK: 讀取

    static func load() throws -> AppConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configFile.path) {
            let config = AppConfig.defaultConfig()
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            let providersDir = configDir.appendingPathComponent("providers")
            try fm.createDirectory(at: providersDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: configFile)
            try writeDefaultProviderScripts(to: providersDir)
            return config
        }
        return try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configFile))
    }

    // MARK: 模型解析

    /// 解析 -m 參數：provider 名稱或 model 名稱
    func resolveModel(_ modelArg: String?) -> (command: String, model: String)? {
        if let modelArg {
            // match provider name
            if let provider = providers[modelArg] {
                return (expandPath(provider.command), provider.defaultModel)
            }
            // match model name across all providers
            for (_, provider) in providers {
                if provider.models.contains(modelArg) {
                    return (expandPath(provider.command), modelArg)
                }
            }
            return nil
        }
        guard let provider = providers[defaultProvider] else { return nil }
        return (expandPath(provider.command), provider.defaultModel)
    }

    var resolvedSocketPath: String {
        expandPath(socketPath)
    }

    private func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
        }
        return path
    }

    // MARK: 預設值

    static func defaultConfig() -> AppConfig {
        AppConfig(
            defaultProvider: "litert",
            providers: [
                "ollama": ProviderConfig(
                    command: "~/.config/omnichat/providers/ollama.sh",
                    defaultModel: "llama3.1:latest",
                    models: ["llama3.1:latest"]
                ),
                "litert": ProviderConfig(
                    command: "~/.config/omnichat/providers/litert.sh",
                    defaultModel: "gemma-4-E4B",
                    models: ["gemma-4-E4B"]
                ),
            ],
            modes: [
                ModeConfig(name: "General", systemPrompt: "You are a helpful assistant."),
                ModeConfig(name: "Coding", systemPrompt: "You are an expert programmer. Provide concise code solutions with explanations."),
            ],
            defaultMode: 0,
            appearance: "system",
            socketPath: "~/.config/omnichat/omnichat.sock",
            hideAfterSend: false,
            theme: ThemeConfig(
                backgroundColor: "#061922",      // iTerm2 Background (Dark, P3)
                backgroundOpacity: 0.80,          // iTerm2 Transparency = 0.20
                backgroundBlur: 20.0,             // iTerm2 Blur Radius ≈ 19.83
                sidebarColor: "#040f18",          // 背景稍深
                userBubbleColor: "#15394E",       // iTerm2 Selection (Dark, P3)
                userTextColor: "#DADADA",         // iTerm2 Foreground (Dark, P3)
                assistantTextColor: "#DADADA",    // iTerm2 Foreground (Dark, P3)
                inputBackgroundColor: "#0a1e2a",  // 背景稍亮
                inputTextColor: "#DADADA",        // iTerm2 Foreground (Dark, P3)
                accentColor: "#78E3FC"            // iTerm2 Cursor (Dark, P3)
            ),
            hotkey: HotkeyConfig(doubleTapKey: "rightOption", doubleTapInterval: 300, longPressThreshold: 500)
        )
    }

    private static func writeDefaultProviderScripts(to dir: URL) throws {
        let script = """
        #!/bin/bash
        # OmniChat Ollama Provider
        # stdin: JSON { "messages": [...], "model": "..." }
        # stdout: 逐行輸出回應文字
        INPUT=$(cat)
        MODEL=$(echo "$INPUT" | jq -r '.model')
        MESSAGES=$(echo "$INPUT" | jq -c '.messages')

        curl -s --no-buffer "http://localhost:11434/api/chat" \\
          -d "{\\"model\\": \\"$MODEL\\", \\"messages\\": $MESSAGES, \\"stream\\": true}" \\
          | while IFS= read -r line; do
            printf '%s' "$(echo "$line" | jq -j '.message.content // empty')"
          done
        """
        let file = dir.appendingPathComponent("ollama.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path
        )
    }
}
