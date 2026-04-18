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
    var audioPath: String?  // 語音對話時的音訊檔案路徑
    var ttsEnabled: Bool?   // TTS 開啟時，提示模型用英文回覆

    init(messages: [ChatMessage], model: String, audioPath: String? = nil, ttsEnabled: Bool? = nil) {
        self.messages = messages
        self.model = model
        self.audioPath = audioPath
        self.ttsEnabled = ttsEnabled
    }
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
    var audioPath: String?  // 語音訊息的音訊檔案路徑

    init(role: String, content: String, audioPath: String? = nil) {
        self.role = role
        self.content = content
        self.audioPath = audioPath
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
    var voice: VoiceConfig?        // 語音對話設定

    /// 輸入類型：文字或音訊
    enum InputType: String, Codable, Sendable {
        case text    // 純文字輸入
        case audio   // 音訊輸入（多模態）
    }

    struct ProviderConfig: Codable, Sendable {
        var command: String
        var defaultModel: String
        var models: [String]
        var inputType: InputType?  // 預設為 .text
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

    /// 語音對話設定
    struct VoiceConfig: Codable, Sendable {
        var enabled: Bool                    // 是否啟用語音功能
        var providerCommand: String          // 語音 provider 腳本路徑（支援 --audio）
        var ttsCommand: String               // TTS 腳本路徑（Kokoro）
        var recordSampleRate: Int?           // 錄音取樣率（預設 16000）
        var feedbackType: String?            // "haptic", "sound", "both"（預設 "both"）
        var ttsPersistent: Bool?             // TTS server 常駐模式（預設 true）
        var ttsPort: Int?                    // TTS server port（預設 19876）
        var ttsSpeed: Double?               // TTS 播放速度（預設 1.5）
        var ttsSentenceGap: Double?         // 句子間播放間隔秒數（預設 0）
        var ttsParagraphGap: Double?        // 換行（段落）間播放間隔秒數（預設 1）
        var ttsMinLength: Int?              // TTS 最短句子長度，短於此會合併（預設 8）
        var ttsStreaming: Bool?             // 邊生成文字邊 TTS（預設 true，false 則等全部完成再 TTS）
        var ttsMaxConcurrent: Int?          // 同時運行的 TTS worker 數（預設 2）
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

    /// 解析 -m 參數：provider 名稱或 model 名稱（僅搜尋文字 provider）
    func resolveModel(_ modelArg: String?) -> (command: String, model: String)? {
        if let modelArg {
            // match provider name（排除 audio provider）
            if let provider = providers[modelArg], provider.inputType != .audio {
                return (expandPath(provider.command), provider.defaultModel)
            }
            // match model name across text providers
            for (_, provider) in providers where provider.inputType != .audio {
                if provider.models.contains(modelArg) {
                    return (expandPath(provider.command), modelArg)
                }
            }
            return nil
        }
        guard let provider = providers[defaultProvider] else { return nil }
        return (expandPath(provider.command), provider.defaultModel)
    }

    /// 從 providers 中尋找 inputType == .audio 的 provider
    func resolveAudioProvider() -> (command: String, model: String)? {
        for (_, provider) in providers {
            if provider.inputType == .audio {
                return (expandPath(provider.command), provider.defaultModel)
            }
        }
        return nil
    }

    /// 解析語音 provider 指令路徑（優先使用 providers 中的 audio provider，向下相容 voice.providerCommand）
    var resolvedVoiceCommand: String? {
        // 優先：providers 中標記為 audio 的 provider
        if let audioProvider = resolveAudioProvider() {
            return audioProvider.command
        }
        // 向下相容：舊的 voice.providerCommand
        guard let voice = voice, voice.enabled else { return nil }
        return expandPath(voice.providerCommand)
    }

    /// 解析 TTS 指令路徑
    var resolvedTTSCommand: String? {
        guard let voice = voice, voice.enabled else { return nil }
        return expandPath(voice.ttsCommand)
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
                    models: ["llama3.1:latest"],
                    inputType: .text
                ),
                "litert": ProviderConfig(
                    command: "~/.config/omnichat/providers/litert.sh",
                    defaultModel: "gemma-4-E4B",
                    models: ["gemma-4-E4B"],
                    inputType: .text
                ),
                "gemma-audio": ProviderConfig(
                    command: "~/.config/omnichat/providers/gemma_audio.py",
                    defaultModel: "google/gemma-4-E2B-it",
                    models: ["google/gemma-4-E2B-it"],
                    inputType: .audio
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
            hotkey: HotkeyConfig(doubleTapKey: "rightOption", doubleTapInterval: 300, longPressThreshold: 500),
            voice: VoiceConfig(
                enabled: true,
                providerCommand: "~/.config/omnichat/providers/gemma_voice.sh",
                ttsCommand: "~/.config/omnichat/tts/kokoro_tts.sh",
                recordSampleRate: 16000,
                feedbackType: "both",
                ttsPersistent: true,
                ttsPort: 19876,
                ttsSpeed: 1.5,
                ttsSentenceGap: 0,
                ttsParagraphGap: 1,
                ttsMinLength: 8,
                ttsStreaming: true,
                ttsMaxConcurrent: 2
            )
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
