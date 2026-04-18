// SettingsView.swift
// OmniChat
// 設定檢視頁面：顯示目前載入的 config 參數，Cmd+, 開啟 config 檔案

import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var reloadMessage: String?

    private var config: AppConfig { appState.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 標題列
                HStack {
                    Text("Settings")
                        .font(.title2.bold())
                    Spacer()
                    // Reload 按鈕
                    Button(action: reloadConfig) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Reload")
                        }
                    }
                    // 開啟 config 檔案
                    Button(action: openConfigFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                            Text("Open config.json")
                        }
                    }
                }

                // Reload 結果訊息
                if let msg = reloadMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("Failed") ? .red : .green)
                        .transition(.opacity)
                }

                Divider()

                // 一般設定
                section("General") {
                    row("Default Provider", config.defaultProvider)
                    row("Default Mode", "\(config.defaultMode) (\(config.modes.indices.contains(config.defaultMode) ? config.modes[config.defaultMode].name : "?"))")
                    row("Max Concurrent Models", "\(config.maxConcurrentModels ?? 1)")
                    row("Hide After Send", "\(config.hideAfterSend ?? false)")
                    row("Appearance", config.appearance)
                }

                // Providers
                section("Providers") {
                    ForEach(config.providers.sorted(by: { $0.key < $1.key }), id: \.key) { name, provider in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.headline)
                            row("  Command", provider.command)
                            row("  Default Model", provider.defaultModel)
                            row("  Models", provider.models.joined(separator: ", "))
                            row("  Input Type", provider.inputType?.rawValue ?? "text")
                        }
                    }
                }

                // Modes
                section("Modes") {
                    ForEach(Array(config.modes.enumerated()), id: \.offset) { i, mode in
                        row("\(i): \(mode.name)", String(mode.systemPrompt.prefix(80)) + (mode.systemPrompt.count > 80 ? "..." : ""))
                    }
                }

                // Voice
                if let voice = config.voice {
                    section("Voice") {
                        row("enabled", "\(voice.enabled)")
                        row("providerCommand", voice.providerCommand)
                        row("(resolved)", config.resolvedVoiceCommand ?? "(none)")
                        row("ttsCommand", voice.ttsCommand)
                        row("recordSampleRate", "\(voice.recordSampleRate ?? 16000)")
                        row("feedbackType", voice.feedbackType ?? "both")
                    }

                    section("TTS") {
                        row("ttsPersistent", "\(voice.ttsPersistent ?? true)")
                        row("ttsPort", "\(voice.ttsPort ?? 19876)")
                        row("ttsSpeed", String(format: "%.1f", voice.ttsSpeed ?? 1.5))
                        row("ttsStreaming", "\(voice.ttsStreaming ?? true)")
                        row("ttsMinLength", "\(voice.ttsMinLength ?? 8)")
                        row("ttsSentenceGap", String(format: "%.2fs", voice.ttsSentenceGap ?? 0))
                        row("ttsParagraphGap", String(format: "%.2fs", voice.ttsParagraphGap ?? 1))
                        row("ttsMaxConcurrent", "\(voice.ttsMaxConcurrent ?? 2)")
                        row("Server Ready", "\(appState.voicePipeline.ttsEngine.isServerReady)")
                    }
                }

                // Hotkey
                if let hotkey = config.hotkey {
                    section("Hotkey") {
                        row("Double Tap Key", hotkey.doubleTapKey)
                        row("Double Tap Interval", "\(hotkey.doubleTapInterval)ms")
                        row("Long Press Threshold", "\(hotkey.longPressThreshold)ms")
                    }
                }

                // Socket
                section("IPC") {
                    row("Socket Path", config.resolvedSocketPath)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(.ultraThinMaterial)
        // 在此頁面時 Cmd+, 開啟 config 檔案
        .onReceive(NotificationCenter.default.publisher(for: .omniOpenConfig)) { _ in
            openConfigFile()
        }
    }

    // MARK: - 輔助元件

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
        Divider()
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .trailing)
                .textSelection(.enabled)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.system(.body, design: .monospaced))
    }

    // MARK: - Actions

    private func reloadConfig() {
        do {
            let newConfig = try AppConfig.load()
            appState.config = newConfig
            appState.voicePipeline.configure(config: newConfig)
            // 重啟 TTS server 以套用新設定
            appState.voicePipeline.ttsEngine.stopServer()
            appState.voicePipeline.ttsEngine.startServer(config: newConfig)
            reloadMessage = "Reloaded successfully"
        } catch {
            reloadMessage = "Failed: \(error.localizedDescription)"
        }
        // 3 秒後清除訊息
        Task {
            try? await Task.sleep(for: .seconds(3))
            reloadMessage = nil
        }
    }

    private func openConfigFile() {
        NSWorkspace.shared.open(AppConfig.configFile)
    }
}
