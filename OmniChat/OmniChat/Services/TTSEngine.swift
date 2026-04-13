// TTSEngine.swift
// OmniChat
// 呼叫外部 Kokoro-82M TTS 腳本，將文字轉為音訊檔案

import Foundation

/// TTS 引擎：呼叫外部 Python 腳本產生語音
@MainActor
class TTSEngine {
    private let outputDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat/tts_output")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 將文字合成為音訊檔案，回傳音檔路徑
    func synthesize(text: String, config: AppConfig) async throws -> URL {
        guard let ttsCommand = config.resolvedTTSCommand else {
            throw TTSError.notConfigured
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TTSError.emptyText
        }

        // 組合 JSON 輸入
        let input: [String: String] = [
            "text": trimmed,
            "voice": "af_heart",
            "output_dir": outputDir.path,
        ]
        let inputJSON = try JSONEncoder().encode(input)

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
