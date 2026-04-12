// main.swift
// omni CLI — OmniChat 的命令列介面
//
// 所有帶 prompt 的指令都會將 model 回覆輸出到 stdout，
// 方便 pipe 和 redirect 操作。GUI 和 CLI 同時顯示回覆。

import ArgumentParser
import Foundation

struct Omni: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "omni",
        abstract: "OmniChat CLI — talk to AI from the terminal",
        version: "0.1.0"
    )

    // MARK: - 對話參數

    @Argument(help: "Prompt to send")
    var prompt: String?

    @Option(name: .shortAndLong, help: "Model or provider name")
    var model: String?

    @Option(name: [.customShort("p"), .long], help: "Mode index")
    var mode: Int?

    @Option(name: [.customShort("c"), .long], help: "Conversation ID")
    var conversation: String?

    @Flag(name: .long, help: "Start new conversation (creates only if no prompt, otherwise creates and sends)")
    var new: Bool = false

    @Flag(name: .long, help: "Bypass app, call provider script directly")
    var silent: Bool = false

    // MARK: - 視窗控制

    @Flag(name: .long, help: "Open new window")
    var newWindow: Bool = false

    @Flag(name: .long, help: "Toggle show/hide")
    var toggle: Bool = false

    @Flag(name: .long, help: "Clear conversation (use with -c for specific, otherwise clears active)")
    var clear: Bool = false

    // MARK: - 查詢

    @Flag(name: .long, help: "List available models")
    var listModels: Bool = false

    @Flag(name: .long, help: "List all modes")
    var listModes: Bool = false

    @Flag(name: .long, help: "List conversations with IDs")
    var history: Bool = false

    mutating func run() throws {
        let config = try AppConfig.load()

        // 無參數指令（不回傳 model 回覆）
        if toggle { try sendIPC(IPCRequest(action: .toggle), config: config); return }
        if clear { try sendIPC(IPCRequest(action: .clear, conversationId: conversation), config: config); return }

        // 查詢指令（不需要 App）
        if listModels {
            for (name, provider) in config.providers.sorted(by: { $0.key < $1.key }) {
                print("\(name):")
                for m in provider.models {
                    let marker = (m == provider.defaultModel) ? " (default)" : ""
                    print("  \(m)\(marker)")
                }
            }
            return
        }

        if listModes {
            for (i, mode) in config.modes.enumerated() {
                let marker = (i == config.defaultMode) ? " (default)" : ""
                print("\(i): \(mode.name)\(marker)")
            }
            return
        }

        if history {
            try sendIPC(IPCRequest(action: .history), config: config)
            return
        }

        // --new-window：單純開新視窗，不帶 prompt
        if newWindow {
            try sendIPC(IPCRequest(action: .newWindow), config: config)
            return
        }

        // 讀取 stdin（如果有 pipe 進來的資料）
        var stdinContent: String? = nil
        if isatty(fileno(Foundation.stdin)) == 0 {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                stdinContent = text
            }
        }

        // 解析 prompt（prompt 參數或 stdin 擇一）
        let promptText: String?
        if let p = prompt {
            promptText = p
        } else if let s = stdinContent, !s.isEmpty {
            promptText = s
            stdinContent = nil
        } else {
            promptText = nil
        }

        // --new 無 prompt：單純建立新對話
        if self.new && (promptText == nil || promptText!.isEmpty) {
            try sendIPC(IPCRequest(action: .newConversation), config: config)
            return
        }

        // 對話指令：一定要有 prompt
        guard let promptText, !promptText.isEmpty else {
            printErr("Error: Please provide a prompt or use --help")
            throw ExitCode.failure
        }

        if silent {
            // Silent 模式：直接呼叫外部腳本，不經過 App
            try runDirect(prompt: promptText, stdinContent: stdinContent, config: config)
        } else {
            // GUI 模式：App 顯示 + stream 回覆到 stdout
            let request = IPCRequest(
                action: .sendPrompt,
                prompt: promptText,
                model: model,
                mode: mode,
                stdin: stdinContent,
                conversationId: conversation,
                newConversation: self.new
            )
            try sendIPC(request, config: config)
        }
    }

    // MARK: - Direct 模式：直接呼叫外部腳本（--silent）

    private func runDirect(prompt: String, stdinContent: String?, config: AppConfig) throws {
        guard let resolved = config.resolveModel(model) else {
            printErr("Error: Model not found '\(model ?? "default")'")
            throw ExitCode.failure
        }

        let modeIndex = mode ?? config.defaultMode
        var messages: [ChatMessage] = []
        if modeIndex < config.modes.count {
            messages.append(ChatMessage(role: "system", content: config.modes[modeIndex].systemPrompt))
        }

        var userContent = prompt
        if let extra = stdinContent, !extra.isEmpty {
            userContent += "\n\n" + extra
        }
        messages.append(ChatMessage(role: "user", content: userContent))

        let input = ProviderInput(messages: messages, model: resolved.model)
        let inputJSON = try JSONEncoder().encode(input)

        // 執行外部腳本
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", resolved.command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        stdinPipe.fileHandleForWriting.write(inputJSON)
        stdinPipe.fileHandleForWriting.closeFile()

        // 即時讀取並輸出
        let handle = stdoutPipe.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            if let text = String(data: data, encoding: .utf8) {
                print(text, terminator: "")
                fflush(Foundation.stdout)
            }
        }

        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if let errText = String(data: errData, encoding: .utf8), !errText.isEmpty {
                FileHandle.standardError.write(Data(errText.utf8))
            }
            throw ExitCode(rawValue: process.terminationStatus)
        }

        print("") // 結尾換行
    }

    // MARK: - IPC 通訊

    private func sendIPC(_ request: IPCRequest, config: AppConfig) throws {
        let socketPath = config.resolvedSocketPath

        // 檢查 socket 是否存在（App 是否運行）
        if !FileManager.default.fileExists(atPath: socketPath) {
            printErr("OmniChat app not running, launching...")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "OmniChat"]
            try task.run()
            task.waitUntilExit()

            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: socketPath) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }

            guard FileManager.default.fileExists(atPath: socketPath) else {
                printErr("Error: Cannot connect to OmniChat app")
                throw ExitCode.failure
            }
        }

        // 連線 Unix Domain Socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            printErr("Error: Cannot create socket")
            throw ExitCode.failure
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    let count = min(src.count, 104)
                    dest.update(from: src.baseAddress!, count: count)
                }
            }
            _ = bound
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            printErr("Error: Cannot connect to OmniChat (socket connect failed)")
            throw ExitCode.failure
        }

        // 發送請求
        let requestData = try JSONEncoder().encode(request)
        var dataToSend = requestData
        dataToSend.append(contentsOf: [0x0A])
        dataToSend.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, ptr.count, 0)
        }

        // 讀取回應（stdout 只有 model 回覆，其他走 stderr）
        var buffer = Data()
        let readBuf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { readBuf.deallocate() }

        while true {
            let bytesRead = recv(fd, readBuf, 4096, 0)
            if bytesRead <= 0 { break }
            buffer.append(readBuf.assumingMemoryBound(to: UInt8.self), count: bytesRead)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = buffer[(newlineIndex + 1)...]

                guard let response = try? JSONDecoder().decode(IPCResponse.self, from: Data(lineData)) else {
                    continue
                }

                switch response.status {
                case .ok:
                    // --history 等查詢結果 → stdout
                    if let msg = response.message { print(msg) }
                    if let data = response.data { data.forEach { print($0) } }
                    if let cid = response.conversationId {
                        printErr("conv:\(cid)")
                    }
                    return
                case .streaming:
                    // model 回覆 chunk → stdout（方便 pipe）
                    if let chunk = response.chunk {
                        print(chunk, terminator: "")
                        fflush(Foundation.stdout)
                    }
                case .done:
                    print("") // 結尾換行
                    if let cid = response.conversationId {
                        printErr("conv:\(cid)")
                    }
                    return
                case .error:
                    if let msg = response.message {
                        printErr("Error: \(msg)")
                    }
                    throw ExitCode.failure
                }
            }
        }
    }

    // MARK: - Helpers

    /// 輸出到 stderr（不污染 stdout）
    private func printErr(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

Omni.main()
