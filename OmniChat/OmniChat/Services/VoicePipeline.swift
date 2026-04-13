// VoicePipeline.swift
// OmniChat
// 語音對話管線 orchestrator
// 錄音 → Gemma 多模態 → 文字串流(UI) → 句子分割 → TTS → 播放

import Foundation
import SwiftData

// MARK: - 句子分割器

/// 累積串流文字，偵測句子邊界後輸出完整句子
class SentenceBuffer {
    private var buffer = ""

    /// 餵入 chunk，回傳完成的句子列表
    func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var sentences: [String] = []

        // 以句號、問號、驚嘆號 + 空白/換行為分割點
        // 支援中英文標點
        while let range = buffer.range(of: #"[.!?。！？\n][\s]*"#, options: .regularExpression) {
            let sentence = String(buffer[buffer.startIndex...range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            buffer = String(buffer[range.upperBound...])
        }

        return sentences
    }

    /// 清空剩餘 buffer，回傳最後未完成的句子
    func flush() -> String? {
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remaining.isEmpty ? nil : remaining
    }

    /// 重置
    func reset() {
        buffer = ""
    }
}

// MARK: - VoicePipeline

/// 語音對話管線：管理錄音 → AI → TTS → 播放的完整流程
@MainActor
@Observable
class VoicePipeline {
    enum State: Sendable {
        case idle           // 待機
        case recording      // 錄音中
        case processing     // Gemma 處理中
        case speaking       // TTS 播放中
    }

    var state: State = .idle
    var currentTranscript = ""  // 目前串流文字（顯示在 UI）

    private let recorder = AudioRecorder()
    private let ttsEngine = TTSEngine()
    private let playbackQueue = AudioPlaybackQueue()
    private let sentenceBuffer = SentenceBuffer()

    // 錄音佇列：等待處理的音訊檔案
    private var recordingQueue: [URL] = []
    private var isProcessingQueue = false

    // 設定
    private var config: AppConfig?

    // 回呼：文字 chunk 送到 UI
    var onTextChunk: ((String) -> Void)?
    // 回呼：一輪語音對話完成（含完整回應文字）
    var onComplete: ((String) -> Void)?
    // 回呼：錯誤發生
    var onError: ((String) -> Void)?

    /// 初始化管線設定
    func configure(config: AppConfig) {
        self.config = config
    }

    // MARK: - 錄音控制（由 HotkeyManager 呼叫）

    /// 開始錄音
    func beginRecording() {
        guard let config = config, config.voice?.enabled == true else {
            print("VoicePipeline: voice not enabled")
            return
        }

        // 檢查麥克風權限
        guard AudioRecorder.hasPermission else {
            Task {
                let granted = await AudioRecorder.requestPermission()
                if granted {
                    self.beginRecording()
                } else {
                    self.onError?("Microphone permission denied")
                }
            }
            return
        }

        // 中斷正在播放的 TTS
        playbackQueue.interruptForNewRecording()

        // 開始錄音
        let sampleRate = config.voice?.recordSampleRate ?? 16000
        if recorder.startRecording(sampleRate: sampleRate) != nil {
            state = .recording
        }
    }

    /// 結束錄音（single click）
    func endRecording() {
        guard state == .recording else { return }

        if let audioURL = recorder.stopRecording() {
            state = .processing
            enqueueRecording(audioURL)
        } else {
            state = .idle
        }
    }

    /// 結束當前錄音 + 開始新錄音（long press while recording）
    func endAndBeginNew() {
        if let audioURL = recorder.stopRecording() {
            enqueueRecording(audioURL)
        }
        // 立即開始新錄音
        let sampleRate = config?.voice?.recordSampleRate ?? 16000
        if recorder.startRecording(sampleRate: sampleRate) != nil {
            state = .recording
        }
    }

    // MARK: - 錄音佇列處理

    /// 將錄音加入佇列
    private func enqueueRecording(_ url: URL) {
        recordingQueue.append(url)
        processQueueIfNeeded()
    }

    /// 如果沒有正在處理，開始處理佇列
    private func processQueueIfNeeded() {
        guard !isProcessingQueue, !recordingQueue.isEmpty else { return }
        isProcessingQueue = true

        Task {
            while !recordingQueue.isEmpty {
                let audioURL = recordingQueue.removeFirst()
                await processAudio(audioURL)
            }
            isProcessingQueue = false

            // 如果不在錄音中，回到 idle
            if state != .recording {
                state = .idle
            }
        }
    }

    // MARK: - Gemma 處理 + TTS 管線

    /// 處理單一音訊：送 Gemma → 串流文字 → TTS → 播放
    private func processAudio(_ audioURL: URL) async {
        guard let config = config,
              let voiceCommand = config.resolvedVoiceCommand else {
            onError?("Voice provider not configured")
            return
        }

        if state != .recording {
            state = .processing
        }

        // 重置句子 buffer
        sentenceBuffer.reset()
        currentTranscript = ""

        // 組合訊息（system prompt + 語音輸入描述）
        let modeIndex = config.defaultMode
        var messages: [ChatMessage] = []
        if modeIndex < config.modes.count {
            messages.append(ChatMessage(role: "system", content: config.modes[modeIndex].systemPrompt))
        }
        messages.append(ChatMessage(role: "user", content: "[Voice Input]", audioPath: audioURL.path))

        let input = ProviderInput(messages: messages, model: "", audioPath: audioURL.path)

        do {
            let inputJSON = try JSONEncoder().encode(input)
            var fullResponse = ""

            // 呼叫 voice provider（串流輸出）
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", voiceCommand]

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // 串流讀取 stdout
                stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        Task { @MainActor in
                            guard let self = self else { return }

                            // 更新 UI 串流文字
                            fullResponse += text
                            self.currentTranscript = fullResponse
                            self.onTextChunk?(text)

                            // 句子分割 → TTS 佇列
                            let sentences = self.sentenceBuffer.feed(text)
                            for sentence in sentences {
                                self.enqueueTTS(sentence)
                            }
                        }
                    }
                }

                process.terminationHandler = { [weak self] proc in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil

                    Task { @MainActor in
                        // flush 剩餘句子
                        if let remaining = self?.sentenceBuffer.flush() {
                            self?.enqueueTTS(remaining)
                        }
                    }

                    if proc.terminationStatus == 0 {
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

            // Gemma 完成，等待 TTS 播放完成
            if state != .recording {
                state = .speaking
            }

            onComplete?(fullResponse)

        } catch {
            onError?(error.localizedDescription)
        }

        // 清理暫存音訊
        try? FileManager.default.removeItem(at: audioURL)
        ttsEngine.cleanup()
    }

    /// 將句子送入 TTS 並排入播放佇列
    private func enqueueTTS(_ sentence: String) {
        guard let config = config else { return }

        Task {
            do {
                let audioURL = try await ttsEngine.synthesize(text: sentence, config: config)
                playbackQueue.enqueue(audioURL)
            } catch {
                print("VoicePipeline: TTS 失敗 - \(error.localizedDescription)")
            }
        }
    }

    /// 停止所有活動
    func stopAll() {
        if recorder.isRecording {
            recorder.stopRecording()
        }
        playbackQueue.stopAll()
        recordingQueue.removeAll()
        sentenceBuffer.reset()
        currentTranscript = ""
        state = .idle
    }
}
