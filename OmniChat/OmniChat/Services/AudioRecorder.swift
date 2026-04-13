// AudioRecorder.swift
// OmniChat
// 麥克風錄音服務：WAV 16kHz mono 格式

import AVFoundation
import AppKit

/// 麥克風錄音管理器
@MainActor
@Observable
class AudioRecorder: NSObject {
    var isRecording = false
    private var audioRecorder: AVAudioRecorder?
    private var currentURL: URL?

    private let tempDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/omnichat/voice_tmp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 開始錄音，回傳錄音檔路徑
    func startRecording(sampleRate: Int = 16000) -> URL? {
        // 清理舊的暫存檔案
        cleanupOldFiles()

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = tempDir.appendingPathComponent("voice_\(timestamp).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            currentURL = url
            isRecording = true
            playFeedback(start: true)
            print("AudioRecorder: 開始錄音 → \(url.lastPathComponent)")
            return url
        } catch {
            print("AudioRecorder: 錄音失敗 - \(error.localizedDescription)")
            return nil
        }
    }

    /// 停止錄音，回傳錄音檔路徑
    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording, let recorder = audioRecorder else { return nil }

        recorder.stop()
        isRecording = false
        playFeedback(start: false)

        let url = currentURL
        audioRecorder = nil
        currentURL = nil
        print("AudioRecorder: 錄音結束 → \(url?.lastPathComponent ?? "nil")")
        return url
    }

    /// 請求麥克風權限
    static func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// 檢查麥克風權限
    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Private

    /// 播放錄音開始/結束回饋
    private func playFeedback(start: Bool) {
        // Haptic 回饋（Force Touch trackpad 才有效）
        NSHapticFeedbackManager.defaultPerformer.perform(
            start ? .levelChange : .alignment,
            performanceTime: .now
        )

        // 系統音效
        if start {
            NSSound(named: "Pop")?.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }

    /// 清理超過 10 分鐘的暫存檔案
    private func cleanupOldFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let cutoff = Date().addingTimeInterval(-600)  // 10 分鐘
        for file in files {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            print("AudioRecorder: 錄音未成功完成")
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            print("AudioRecorder: 編碼錯誤 - \(error.localizedDescription)")
        }
    }
}
