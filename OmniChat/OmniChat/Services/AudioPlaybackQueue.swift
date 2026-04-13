// AudioPlaybackQueue.swift
// OmniChat
// 音訊播放佇列：依序播放 TTS 產出的音檔

import AVFoundation

/// 音訊播放佇列，依序播放音檔
/// 支援中斷播放（新錄音開始時）
class AudioPlaybackQueue: NSObject {
    private var queue: [URL] = []
    private var player: AVAudioPlayer?
    private var isPlaying = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// 目前是否正在播放
    var playing: Bool { isPlaying }

    /// 加入音檔到播放佇列
    func enqueue(_ url: URL) {
        queue.append(url)
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

        let url = queue.removeFirst()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            isPlaying = true
        } catch {
            print("AudioPlaybackQueue: 播放失敗 - \(error.localizedDescription)")
            // 跳過失敗的，繼續下一個
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

    /// 等待所有佇列播放完成
    func waitUntilDone() async {
        guard isPlaying || !queue.isEmpty else { return }
        await withCheckedContinuation { cont in
            self.continuation = cont
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackQueue: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        if queue.isEmpty {
            isPlaying = false
            // 通知等待者播放完成
            continuation?.resume()
            continuation = nil
        } else {
            playNext()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("AudioPlaybackQueue: 解碼錯誤 - \(error?.localizedDescription ?? "unknown")")
        self.player = nil
        if queue.isEmpty {
            isPlaying = false
            continuation?.resume()
            continuation = nil
        } else {
            playNext()
        }
    }
}
