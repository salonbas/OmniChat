// ChatEngine.swift
// OmniChat
// 管理對話邏輯，呼叫外部腳本取得 AI 回應

import Foundation

/// 並行限制信號量（非 MainActor，可在任意執行緒使用）
private actor ModelSemaphore {
    private var maxConcurrent: Int
    private var currentCount: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func setMax(_ max: Int) {
        maxConcurrent = max
    }

    func acquire() async {
        if currentCount < maxConcurrent {
            currentCount += 1
            return
        }
        // 排隊等待
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            currentCount -= 1
        }
    }
}

/// 聊天引擎：負責呼叫外部 provider 腳本
@MainActor
@Observable
class ChatEngine {
    var isStreaming = false

    /// 並行模型數量限制（預設 1，同一時間只跑一個）
    private let semaphore = ModelSemaphore(maxConcurrent: 1)

    /// 更新並行限制
    func setMaxConcurrent(_ max: Int) {
        Task { await semaphore.setMax(max) }
    }

    /// 呼叫外部腳本進行對話（串流回應）
    func sendMessage(
        messages: [ChatMessage],
        config: AppConfig,
        modelOverride: String? = nil,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let resolved = config.resolveModel(modelOverride) else {
            throw ChatError.modelNotFound(modelOverride ?? "default")
        }

        let input = ProviderInput(messages: messages, model: resolved.model)
        let inputJSON = try JSONEncoder().encode(input)

        // 等待信號量（排隊）
        await semaphore.acquire()
        defer { Task { await semaphore.release() } }

        isStreaming = true
        defer { isStreaming = false }

        // 用 nonisolated(unsafe) 讓 onCancel closure 能存取 process
        nonisolated(unsafe) var currentProcess: Process? = nil
        nonisolated(unsafe) var cancelled = false

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                currentProcess = process
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", resolved.command]

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // 讀取 stdout（在背景執行緒）
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        Task { @MainActor in
                            onChunk(text)
                        }
                    }
                }

                process.terminationHandler = { proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: ChatError.scriptFailed(errMsg))
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
        } onCancel: {
            cancelled = true
            currentProcess?.terminate()
        }
    }
}

enum ChatError: LocalizedError {
    case modelNotFound(String)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "Model not found: \(name)"
        case .scriptFailed(let msg): return "Script execution failed: \(msg)"
        }
    }
}
