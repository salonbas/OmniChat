// AppDelegate.swift
// OmniChat
// 管理 App 生命週期、視窗建立、全域 hotkey、語音管線

import AppKit
import SwiftUI
import SwiftData

extension Notification.Name {
    static let omniClearConversation = Notification.Name("omniClearConversation")
    static let omniNewConversation = Notification.Name("omniNewConversation")
    static let omniOpenConfig = Notification.Name("omniOpenConfig")
}

// MARK: - 全域 App 狀態

@MainActor
@Observable
class AppState {
    var config: AppConfig
    let udsServer = UDSServer()
    let voicePipeline = VoicePipeline()

    /// CLI 透過 IPC 送來的待處理請求（ContentView 觀察並執行）
    var pendingPrompt: PendingPrompt?
    /// 遞增計數器，觸發 ContentView 的 onChange
    var pendingPromptVersion: Int = 0

    struct PendingPrompt {
        let prompt: String
        let model: String?
        let mode: Int?
        let conversationId: String?
        let newConversation: Bool
        let respond: (IPCResponse) -> Void
    }

    init() {
        self.config = (try? AppConfig.load()) ?? AppConfig.defaultConfig()
        voicePipeline.configure(config: self.config)
    }

    func startServer(onRequest: @escaping (IPCRequest, @escaping (IPCResponse) -> Void) -> Void) {
        udsServer.start(config: config, onRequest: onRequest)
    }

    func stopServer() {
        udsServer.stop()
    }
}

@MainActor
final class OmniChatAppDelegate: NSObject, NSApplicationDelegate {
    // 全域狀態，整個 App 共用
    let chatEngine = ChatEngine()
    let appState = AppState()
    private let hotkeyManager = HotkeyManager()

    // 視窗管理
    private var windowControllers: [ChatWindowController] = []

    // SwiftData 容器
    lazy var modelContainer: ModelContainer = {
        let schema = Schema([Conversation.self, Message.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Cannot create ModelContainer: \(error)")
        }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 設定並行模型��制
        chatEngine.setMaxConcurrent(appState.config.maxConcurrentModels ?? 1)
        // 建立主視窗
        openNewWindow()
        // 啟動 UDS Server（接收 CLI 的 IPC 請求）
        startUDSServer()
        // 設定 hotkey（含語音錄音）
        setupHotkeys()
        // ��動 TTS server（常駐模式）
        appState.voicePipeline.ttsEngine.startServer(config: appState.config)
        // 設定 Dock 不顯示（可選）
        // NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.stopServer()
        appState.voicePipeline.stopAll()
        // 關閉 TTS server
        appState.voicePipeline.ttsEngine.stopServer()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openNewWindow()
        } else {
            focusApp()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - 視窗管理

    func openNewWindow() {
        let controller = ChatWindowController(
            chatEngine: chatEngine,
            appState: appState,
            modelContainer: modelContainer
        )
        windowControllers.append(controller)
        controller.showWindow(nil)

        // 視窗關閉時從陣列移除
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
        }
    }

    // MARK: - Hotkey

    private func setupHotkeys() {
        // 雙擊 Right Option: toggle focus
        hotkeyManager.onDoubleTap = { [weak self] in
            guard let self else { return }
            if NSApp.isActive {
                NSApp.hide(nil)
            } else {
                self.focusApp()
            }
        }

        // 長按 Right Option: 開始錄音（先檢查 audio provider）
        hotkeyManager.onLongPressStart = { [weak self] in
            guard let self else { return }
            // 檢查是否有 audio provider
            guard self.appState.voicePipeline.hasAudioProvider else {
                self.showAudioProviderError()
                return
            }
            self.appState.voicePipeline.beginRecording()
            self.hotkeyManager.isRecording = true
        }

        // 單擊 Right Option（錄音中）: 結束錄音
        hotkeyManager.onSingleTap = { [weak self] in
            guard let self else { return }
            self.appState.voicePipeline.endRecording()
            self.hotkeyManager.isRecording = false
        }

        hotkeyManager.start(config: appState.config)
    }

    // MARK: - UDS Server

    private func startUDSServer() {
        appState.startServer { [weak self] request, respond in
            guard let self else { return }
            self.handleIPCRequest(request, respond: respond)
        }
    }

    private func handleIPCRequest(_ request: IPCRequest, respond: @escaping (IPCResponse) -> Void) {
        switch request.action {
        case .toggle:
            if NSApp.isActive {
                NSApp.hide(nil)
            } else {
                focusApp()
            }
            respond(IPCResponse(status: .ok))

        case .newWindow:
            openNewWindow()
            focusApp()
            respond(IPCResponse(status: .ok))

        case .newConversation:
            // 在現有視窗建立新對話
            focusApp()
            NotificationCenter.default.post(name: .omniNewConversation, object: nil)
            respond(IPCResponse(status: .ok))

        case .clear:
            // 清空指定對話或 active 對話
            if let cid = request.conversationId, let uuid = UUID(uuidString: cid) {
                let context = modelContainer.mainContext
                let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == uuid })
                if let conv = try? context.fetch(descriptor).first {
                    for msg in conv.messages {
                        context.delete(msg)
                    }
                    conv.messages.removeAll()
                    conv.updatedAt = Date()
                    respond(IPCResponse(status: .ok))
                } else {
                    respond(IPCResponse(status: .error, message: "Conversation ID not found: \(cid)"))
                }
            } else {
                // 無 ID，通知 active ContentView 清空
                NotificationCenter.default.post(name: .omniClearConversation, object: nil)
                respond(IPCResponse(status: .ok))
            }

        case .listModels:
            let models = appState.config.providers.sorted(by: { $0.key < $1.key }).flatMap { (name, provider) in
                provider.models.map { m in
                    let marker = (m == provider.defaultModel) ? " (default)" : ""
                    let typeTag = provider.inputType == .audio ? " [audio]" : ""
                    return "\(name): \(m)\(marker)\(typeTag)"
                }
            }
            respond(IPCResponse(status: .ok, data: models))

        case .listModes:
            let modes = appState.config.modes.enumerated().map { (i, mode) in
                let marker = (i == appState.config.defaultMode) ? " (default)" : ""
                return "\(i): \(mode.name)\(marker)"
            }
            respond(IPCResponse(status: .ok, data: modes))

        case .history:
            let context = modelContainer.mainContext
            let descriptor = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\Conversation.updatedAt, order: .reverse)])
            let convs = (try? context.fetch(descriptor)) ?? []
            let titles = convs.prefix(20).map { "\($0.id.uuidString)\t\($0.title) (\($0.updatedAt.formatted()))" }
            respond(IPCResponse(status: .ok, data: Array(titles)))

        case .sendPrompt:
            // 驗證 conversationId
            if let cid = request.conversationId {
                guard let uuid = UUID(uuidString: cid) else {
                    respond(IPCResponse(status: .error, message: "Invalid conversation ID format: \(cid)"))
                    return
                }
                let context = modelContainer.mainContext
                let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == uuid })
                let count = (try? context.fetchCount(descriptor)) ?? 0
                if count == 0 {
                    respond(IPCResponse(status: .error, message: "Conversation ID not found: \(cid)"))
                    return
                }
            }
            dispatchPrompt(request, respond: respond)
        }
    }

    /// 透過 AppState 將 prompt 派發給 active ContentView
    /// ContentView 負責將訊息存入 SwiftData 並呼叫 ChatEngine
    /// 回覆透過 respond 回傳給 CLI（stream → stdout）
    private func dispatchPrompt(_ request: IPCRequest, forceNew: Bool = false, respond: @escaping (IPCResponse) -> Void) {
        guard let prompt = request.prompt else {
            respond(IPCResponse(status: .error, message: "Missing prompt"))
            return
        }

        var fullPrompt = prompt
        if let stdin = request.stdin, !stdin.isEmpty {
            fullPrompt += "\n\n" + stdin
        }

        // 設定 pendingPrompt 並遞增版本號觸發 ContentView
        appState.pendingPrompt = AppState.PendingPrompt(
            prompt: fullPrompt,
            model: request.model,
            mode: request.mode,
            conversationId: request.conversationId,
            newConversation: forceNew || request.newConversation,
            respond: respond
        )
        appState.pendingPromptVersion += 1
    }

    // MARK: - Helpers

    /// 顯示缺少 audio provider 的錯誤提示
    private func showAudioProviderError() {
        focusApp()
        let alert = NSAlert()
        alert.messageText = "No Audio Provider"
        alert.informativeText = "No audio provider configured.\nAdd a provider with inputType \"audio\" in ~/.config/omnichat/config.json"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Config")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppConfig.configFile)
        }
    }

    func focusApp() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 把所有視窗都拉到前面
        if windowControllers.isEmpty {
            openNewWindow()
        } else {
            for controller in windowControllers {
                controller.window?.orderFront(nil)
            }
            // 最後一個視窗設為 key window
            windowControllers.last?.window?.makeKeyAndOrderFront(nil)
        }
    }

}
