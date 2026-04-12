// ContentView.swift
// OmniChat
// 主聊天介面

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ChatEngine.self) private var chatEngine
    @Environment(AppState.self) private var appState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var selectedConversation: Conversation?
    @State private var inputText = ""
    @State private var streamingText = ""
    @State private var selectedModel: String?
    @State private var selectedMode: Int?
    @State private var keyMonitor: Any?
    @FocusState private var isInputFocused: Bool

    private var theme: Theme { Theme(config: appState.config.theme) }

    var body: some View {
        ZStack {
            // 底層完全透明：背景色和 blur 由 ChatWindowController 透過 window.backgroundColor
            // 和 SkyLight API 設定，SwiftUI 不需要額外背景
            Color.clear.ignoresSafeArea()

            // 上層：自訂佈局，完全透明背景
            HStack(spacing: 0) {
                // 側邊欄
                sidebarView
                    .frame(width: 220)
                    .background(Color.clear)

                Divider()

                // 聊天區域
                if let conv = selectedConversation {
                    chatView(for: conv)
                } else {
                    ContentUnavailableView("選擇或建立對話", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .tint(theme.accentColor)
        .onChange(of: selectedConversation) {
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .omniClearConversation)) { _ in
            if let conv = selectedConversation {
                for msg in conv.messages {
                    modelContext.delete(msg)
                }
                conv.messages.removeAll()
                conv.updatedAt = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .omniNewConversation)) { _ in
            createNewConversation()
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isInputFocused = true
        }
        .onChange(of: appState.pendingPromptVersion) {
            handlePendingPrompt()
        }
        .onAppear {
            if conversations.isEmpty {
                createNewConversation()
            } else {
                selectedConversation = conversations.first
            }
            isInputFocused = true
            // 全域攔截鍵盤快捷鍵
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
                    return event
                }
                switch event.keyCode {
                case 51: // Cmd+Delete：刪除對話
                    deleteSelectedConversation()
                    return nil
                case 17: // Cmd+T：同視窗新增對話
                    createNewConversation()
                    return nil
case 43: // Cmd+,：開啟 config 檔案
                    openConfigFile()
                    return nil
                default:
                    break
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    // MARK: - 側邊欄

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // 標題列區域（因為 fullSizeContentView，需要留出 titlebar 空間）
            HStack {
                Text("OmniChat")
                    .font(.headline)
                    .foregroundStyle(theme.assistantTextColor)
                Spacer()
                Button(action: createNewConversation) {
                    Image(systemName: "plus")
                        .foregroundStyle(theme.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 40) // titlebar 高度
            .padding(.bottom, 8)

            Divider()

            // 對話列表
            List(selection: $selectedConversation) {
                ForEach(conversations) { conv in
                    Text(conv.title)
                        .lineLimit(1)
                        .foregroundStyle(theme.assistantTextColor)
                        .tag(conv)
                        .contextMenu {
                            Button("刪除", role: .destructive) {
                                if selectedConversation == conv {
                                    selectedConversation = nil
                                }
                                modelContext.delete(conv)
                            }
                        }
                }
                .onDelete(perform: deleteConversations)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - 聊天視圖

    @ViewBuilder
    private func chatView(for conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            // 頂部：模型與模式選擇
            HStack {
                // 模式選擇
                Picker("模式", selection: Binding(
                    get: { selectedMode ?? appState.config.defaultMode },
                    set: { selectedMode = $0 }
                )) {
                    ForEach(Array(appState.config.modes.enumerated()), id: \.offset) { i, mode in
                        Text(mode.name).tag(i)
                    }
                }
                .frame(width: 120)

                // 模型選擇
                Picker("模型", selection: Binding(
                    get: { selectedModel ?? appState.config.providers[appState.config.defaultProvider]?.defaultModel ?? "" },
                    set: { selectedModel = $0 }
                )) {
                    ForEach(Array(appState.config.providers.sorted(by: { $0.key < $1.key })), id: \.key) { name, provider in
                        ForEach(provider.models, id: \.self) { model in
                            Text("\(name)/\(model)").tag(model)
                        }
                    }
                }
                .frame(width: 200)

                Spacer()

                if chatEngine.isStreaming {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal)
            .padding(.top, 44) // titlebar 高度
            .padding(.bottom, 8)

            Divider()

            // 訊息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(conversation.messages.sorted(by: { $0.createdAt < $1.createdAt })) { msg in
                            MessageBubble(message: msg, theme: theme)
                                .id(msg.id)
                        }

                        // 串流中的回應
                        if !streamingText.isEmpty {
                            HStack(alignment: .top) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(theme.accentColor)
                                Text(streamingText)
                                    .foregroundStyle(theme.assistantTextColor)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .id("streaming")
                        }
                    }
                    .padding(.vertical)
                }
                .onChange(of: conversation.messages.count) {
                    if let last = conversation.messages.sorted(by: { $0.createdAt < $1.createdAt }).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: streamingText) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }

            Divider()

            // 輸入框
            HStack(alignment: .bottom) {
                TextField("輸入訊息...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.inputTextColor)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .onSubmit {
                        if !NSEvent.modifierFlags.contains(.shift) {
                            sendMessage(to: conversation)
                        }
                    }

                Button(action: { sendMessage(to: conversation) }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(theme.accentColor)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatEngine.isStreaming)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
            .background(Color.clear)
        }
    }

    // MARK: - Actions

    private func createNewConversation() {
        let modeIndex = selectedMode ?? appState.config.defaultMode
        let conv = Conversation(title: "新對話", modeIndex: modeIndex)
        modelContext.insert(conv)
        selectedConversation = conv
        isInputFocused = true
    }

    private func deleteConversations(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(conversations[index])
        }
    }

    private func deleteSelectedConversation() {
        guard let conv = selectedConversation else { return }
        // 刪除前先決定下一個要選的對話
        if let index = conversations.firstIndex(of: conv) {
            if conversations.count > 1 {
                // 非最頂部：選上方；已在最頂部：選最下方
                let nextIndex = index > 0 ? index - 1 : conversations.count - 1
                selectedConversation = conversations[nextIndex]
            } else {
                selectedConversation = nil
            }
        }
        modelContext.delete(conv)
    }

    private func openConfigFile() {
        NSWorkspace.shared.open(AppConfig.configFile)
    }

    private func sendMessage(to conversation: Conversation) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // 送出後隱藏 app
        if appState.config.hideAfterSend == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.hide(nil)
            }
        }

        // 新增使用者訊息
        let userMsg = Message(role: "user", content: text)
        userMsg.conversation = conversation
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()

        // 更新標題（第一則訊息時）
        if conversation.messages.count == 1 {
            conversation.title = String(text.prefix(30))
        }

        // 組合歷史訊息
        let modeIndex = selectedMode ?? conversation.modeIndex
        var chatMessages: [ChatMessage] = []
        if modeIndex < appState.config.modes.count {
            chatMessages.append(ChatMessage(role: "system", content: appState.config.modes[modeIndex].systemPrompt))
        }
        for msg in conversation.messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            chatMessages.append(ChatMessage(role: msg.role, content: msg.content))
        }

        // 呼叫 AI
        streamingText = ""
        Task {
            do {
                try await chatEngine.sendMessage(
                    messages: chatMessages,
                    config: appState.config,
                    modelOverride: selectedModel
                ) { chunk in
                    streamingText += chunk
                }

                let assistantMsg = Message(role: "assistant", content: streamingText, model: selectedModel)
                assistantMsg.conversation = conversation
                conversation.messages.append(assistantMsg)
                conversation.updatedAt = Date()
                streamingText = ""
            } catch {
                let errorMsg = Message(role: "assistant", content: "⚠️ \(error.localizedDescription)")
                errorMsg.conversation = conversation
                conversation.messages.append(errorMsg)
                streamingText = ""
            }
        }
    }

    // MARK: - IPC Prompt 處理

    /// 處理 AppDelegate 透過 AppState 派發的 prompt
    private func handlePendingPrompt() {
        guard let pending = appState.pendingPrompt else { return }

        let respond = pending.respond

        // 決定對話
        let conv: Conversation
        if pending.newConversation {
            let c = Conversation()
            modelContext.insert(c)
            selectedConversation = c
            conv = c
        } else {
            conv = selectedConversation ?? {
                let c = Conversation()
                modelContext.insert(c)
                selectedConversation = c
                return c
            }()
        }

        // 設定 model/mode
        if let m = pending.model { selectedModel = m }
        if let p = pending.mode { selectedMode = p }

        // 新增使用者訊息到 UI
        let userMsg = Message(role: "user", content: pending.prompt)
        userMsg.conversation = conv
        conv.messages.append(userMsg)
        conv.updatedAt = Date()
        if conv.messages.count == 1 {
            conv.title = String(pending.prompt.prefix(30))
        }

        // 組合歷史訊息
        let modeIndex = pending.mode ?? conv.modeIndex
        var chatMessages: [ChatMessage] = []
        if modeIndex < appState.config.modes.count {
            chatMessages.append(ChatMessage(role: "system", content: appState.config.modes[modeIndex].systemPrompt))
        }
        for msg in conv.messages.sorted(by: { $0.createdAt < $1.createdAt }) {
            chatMessages.append(ChatMessage(role: msg.role, content: msg.content))
        }

        // 清除 pending（避免重複處理）
        appState.pendingPrompt = nil

        // 呼叫 AI，同時 stream 到 UI 和 CLI stdout
        streamingText = ""
        Task {
            do {
                try await chatEngine.sendMessage(
                    messages: chatMessages,
                    config: appState.config,
                    modelOverride: pending.model
                ) { chunk in
                    streamingText += chunk
                    respond(IPCResponse(status: .streaming, chunk: chunk))
                }

                // 儲存回覆
                let assistantMsg = Message(role: "assistant", content: streamingText, model: pending.model)
                assistantMsg.conversation = conv
                conv.messages.append(assistantMsg)
                conv.updatedAt = Date()
                streamingText = ""

                respond(IPCResponse(status: .done, conversationId: conv.id.uuidString))
            } catch {
                let errorMsg = Message(role: "assistant", content: "⚠️ \(error.localizedDescription)")
                errorMsg.conversation = conv
                conv.messages.append(errorMsg)
                streamingText = ""
                respond(IPCResponse(status: .error, message: error.localizedDescription))
            }
        }
    }
}

// MARK: - 訊息氣泡

struct MessageBubble: View {
    let message: Message
    let theme: Theme

    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" {
                Spacer()
                Text(message.content)
                    .foregroundStyle(theme.userTextColor)
                    .padding(10)
                    .background(theme.userBubbleColor.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            } else {
                Image(systemName: "sparkles")
                    .foregroundStyle(theme.accentColor)
                Text(message.content)
                    .foregroundStyle(theme.assistantTextColor)
                    .textSelection(.enabled)
                Spacer()
            }
        }
        .padding(.horizontal)
    }
}
