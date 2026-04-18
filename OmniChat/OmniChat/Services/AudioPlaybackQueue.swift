// AudioPlaybackQueue.swift
// OmniChat
// 音訊播放佇列：依序播放 TTS 產出的音檔

import AVFoundation

/// 音訊播放佇列，依序播放音檔
/// 支援中斷播放（新錄音開始時）
/// 播放佇列項目，包含音檔路徑和播放後的間隔
struct PlaybackItem {
    let url: URL
    let gapAfter: Double  // 播放完後暫停秒數
}

@MainActor
class AudioPlaybackQueue: NSObject {
    private var queue: [PlaybackItem] = []
    private var player: AVAudioPlayer?
    private var isPlaying = false
    private var currentGapAfter: Double = 0

    /// 句子間播放間隔秒數
    var sentenceGap: Double = 0
    /// 段落間播放間隔秒數
    var paragraphGap: Double = 1
    /// 播放速率（AVAudioPlayer rate，需配合 Kokoro speed 使用）
    var playbackRate: Float = 1.0

    /// 目前是否正在播放
    var playing: Bool { isPlaying }

    /// 加入音檔到播放佇列（指定播放後間隔）
    func enqueue(_ url: URL, isParagraphEnd: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("AudioPlaybackQueue: 檔案不存在 - \(url.path)")
            return
        }
        let gap = isParagraphEnd ? paragraphGap : sentenceGap
        queue.append(PlaybackItem(url: url, gapAfter: gap))
        if !isPlaying {
            playNext()
        }
    }

    /// 播放下一個音檔
    private func playNext() {
        guard !queue.isEmpty else {
            isPlaying = false
            return
        }

        let item = queue.removeFirst()
        currentGapAfter = item.gapAfter
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: item.url)
            newPlayer.delegate = self
            newPlayer.enableRate = true
            newPlayer.rate = playbackRate
            newPlayer.prepareToPlay()
            self.player = newPlayer
            newPlayer.play()
            isPlaying = true
        } catch {
            print("AudioPlaybackQueue: 播放失敗 - \(error.localizedDescription)")
            playNext()
        }
    }

    /// 停止所有播放並清空佇列
    func stopAll() {
        queue.removeAll()
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// 新錄音開始時中斷播放 + 清空待播佇列
    func interruptForNewRecording() {
        stopAll()
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackQueue: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if self.queue.isEmpty {
                self.isPlaying = false
            } else if self.currentGapAfter > 0 {
                try? await Task.sleep(for: .milliseconds(Int(self.currentGapAfter * 1000)))
                self.playNext()
            } else {
                self.playNext()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            print("AudioPlaybackQueue: 解碼錯誤 - \(error?.localizedDescription ?? "unknown")")
            self.player = nil
            if self.queue.isEmpty {
                self.isPlaying = false
            } else {
                self.playNext()
            }
        }
    }
}
