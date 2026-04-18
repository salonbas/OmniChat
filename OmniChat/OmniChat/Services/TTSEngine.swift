// TTSEngine.swift
// OmniChat
// TTS 引擎：支援常駐 server 模式（快）和腳本模式（相容）

import Foundation

/// TTS 引擎：管理 Kokoro server 生命週期 + 合成請求
@MainActor
class TTSEngine {
    private let outputDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat/tts_output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Server 模式
    private var serverProcess: Process?
    private var serverPort: Int = 19876
    private(set) var isServerReady = false

    // MARK: - Server 生命週期

    /// 啟動 TTS server（App 啟動時呼叫）
    func startServer(config: AppConfig) {
        guard let voice = config.voice,
              voice.ttsPersistent != false else { return }

        let port = voice.ttsPort ?? 19876
        self.serverPort = port

        // 組合 server 啟動指令
        let venvPython = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat/tts/venv/bin/python3").path
        let serverScript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat/tts/kokoro_server.py").path

        // 檢查檔案是否存在
        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            print("TTSEngine: server 檔案不存在，跳過啟動")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPython)
        process.arguments = [serverScript, String(port)]

        // 設定 venv 環境
        var env = ProcessInfo.processInfo.environment
        let venvDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat/tts/venv").path
        env["VIRTUAL_ENV"] = venvDir
        env["PATH"] = "\(venvDir)/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 讀取 stderr 的 log
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            print("TTSEngine: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 等待 stdout 輸出 "ready"
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == "ready" {
                Task { @MainActor in
                    self?.isServerReady = true
                    print("TTSEngine: server 已就緒 (port \(self?.serverPort ?? 0))")
                }
                // 不再需要讀 stdout
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isServerReady = false
                self?.serverProcess = nil
                print("TTSEngine: server 已停止")
            }
        }

        do {
            try process.run()
            self.serverProcess = process
            print("TTSEngine: server 啟動中 (port \(port))...")
        } catch {
            print("TTSEngine: server 啟動失敗 - \(error.localizedDescription)")
        }
    }

    /// 停止 TTS server（App 關閉時呼叫）
    func stopServer() {
        guard let process = serverProcess, process.isRunning else { return }
        process.terminate()
        serverProcess = nil
        isServerReady = false
        print("TTSEngine: server 已終止")
    }

    // MARK: - 合成

    /// 將文字合成為音訊檔案，回傳音檔路徑
    func synthesize(text: String, config: AppConfig) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSError.emptyText
        }

        // 優先用 server 模式
        if isServerReady {
            return try await synthesizeViaServer(text: trimmed, config: config)
        }

        // 退回腳本模式
        return try await synthesizeViaScript(text: trimmed, config: config)
    }

    // MARK: - Server 模式（HTTP）

    private func synthesizeViaServer(text: String, config: AppConfig) async throws -> URL {
        let speed = config.voice?.ttsSpeed ?? 1.5
        let body: [String: Any] = [
            "text": text,
            "voice": "af_heart",
            "speed": speed,
            "output_dir": outputDir.path,
        ]

        let url = URL(string: "http://127.0.0.1:\(serverPort)/synthesize")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.noOutput
        }

        guard httpResponse.statusCode == 200 else {
            let errMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TTSError.scriptFailed(errMsg)
        }

        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = result["path"] as? String, !path.isEmpty else {
            throw TTSError.noOutput
        }

        return URL(fileURLWithPath: path)
    }

    // MARK: - 腳本模式（舊版相容）

    private func synthesizeViaScript(text: String, config: AppConfig) async throws -> URL {
        guard let ttsCommand = config.resolvedTTSCommand else {
            throw TTSError.notConfigured
        }

        let speed = config.voice?.ttsSpeed ?? 1.5
        let input: [String: Any] = [
            "text": text,
            "voice": "af_heart",
            "speed": speed,
            "output_dir": outputDir.path,
        ]
        let inputJSON = try JSONSerialization.data(withJSONObject: input)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", ttsCommand]

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !output.isEmpty {
                        continuation.resume(returning: URL(fileURLWithPath: output))
                    } else {
                        continuation.resume(throwing: TTSError.noOutput)
                    }
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown TTS error"
                    continuation.resume(throwing: TTSError.scriptFailed(errMsg))
                }
            }

            do {
                try process.run()
                stdinPipe.fileHandleForWriting.write(inputJSON)
                stdinPipe.fileHandleForWriting.closeFile()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - 清理

    /// 清理舊的 TTS 輸出檔案
    func cleanup(olderThan seconds: TimeInterval = 600) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for file in files {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}

enum TTSError: LocalizedError {
    case notConfigured
    case emptyText
    case noOutput
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "TTS not configured in voice settings"
        case .emptyText: return "Cannot synthesize empty text"
        case .noOutput: return "TTS script produced no output"
        case .scriptFailed(let msg): return "TTS failed: \(msg)"
        }
    }
}
