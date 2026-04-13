// HotkeyManager.swift
// OmniChat
// 監聽 Right Option 鍵：
// - 雙擊: toggle focus
// - 長按: 開始錄音
// - 單擊 (錄音中): 結束錄音
// - 長按 (錄音中): 結束當前錄音 + 開始新錄音

import Cocoa

/// Global Hotkey 管理器
@MainActor
@Observable
class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Right Option 狀態追蹤
    private var tapTimes: [TimeInterval] = []  // 記錄最近的 keyUp 時間
    private var tapActionTimer: Timer?  // 延遲判斷幾次 tap

    // 長按追蹤
    private var keyDownTime: TimeInterval?     // 記錄 keyDown 時間
    private var longPressTimer: Timer?         // 長按偵測計時器
    private var isKeyDown = false              // 目前 key 是否按著

    // 設定值
    private var multiTapInterval: TimeInterval = 0.35  // 多擊間隔（秒）
    private var longPressThreshold: TimeInterval = 0.5  // 長按門檻（秒）

    // 回呼
    var onDoubleTap: (() -> Void)?        // 雙擊: toggle
    var onLongPressStart: (() -> Void)?   // 長按開始（開始錄音）
    var onSingleTap: (() -> Void)?        // 單擊（錄音中結束錄音）

    // 外部設定的錄音狀態
    var isRecording: Bool = false

    func start(config: AppConfig) {
        if let hotkey = config.hotkey {
            multiTapInterval = Double(hotkey.doubleTapInterval) / 1000.0
            longPressThreshold = Double(hotkey.longPressThreshold) / 1000.0
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let unmanagedSelf = Unmanaged.passUnretained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleFlagsChangedSync(event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: unmanagedSelf.toOpaque()
        ) else {
            print("HotkeyManager: Cannot create event tap, check Accessibility permissions")
            requestAccessibilityPermission()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("HotkeyManager: Right Option listener started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tapActionTimer?.invalidate()
        longPressTimer?.invalidate()
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Private

    private nonisolated func handleFlagsChangedSync(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 61 else { return }  // Right Option

        let flags = event.flags
        let isDown = flags.contains(.maskAlternate)
        let now = ProcessInfo.processInfo.systemUptime

        Task { @MainActor in
            if isDown {
                self.handleKeyDown(time: now)
            } else {
                self.handleKeyUp(time: now)
            }
        }
    }

    private func handleKeyDown(time: TimeInterval) {
        // 取消 tap action timer（還在等待更多 tap）
        tapActionTimer?.invalidate()
        longPressTimer?.invalidate()

        isKeyDown = true
        keyDownTime = time

        // 啟動長按計時器
        longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isKeyDown else { return }
                self.handleLongPress()
            }
        }
    }

    private func handleKeyUp(time: TimeInterval) {
        // 取消長按計時器
        longPressTimer?.invalidate()
        longPressTimer = nil
        isKeyDown = false

        // 計算按住時間
        let holdDuration: TimeInterval
        if let downTime = keyDownTime {
            holdDuration = time - downTime
        } else {
            holdDuration = 0
        }
        keyDownTime = nil

        // 如果是長按後放開，不做任何事（長按動作已在 timer 中觸發）
        if holdDuration >= longPressThreshold {
            return
        }

        // 短按（tap）
        if isRecording {
            // 錄音中的單擊 → 結束錄音
            tapTimes.removeAll()
            onSingleTap?()
        } else {
            // 非錄音中 → 走原本 double-tap 邏輯
            tapTimes = tapTimes.filter { time - $0 < multiTapInterval }
            tapTimes.append(time)

            // 延遲判斷：等一小段時間看有沒有更多 tap
            tapActionTimer?.invalidate()
            tapActionTimer = Timer.scheduledTimer(withTimeInterval: multiTapInterval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    let count = self.tapTimes.count
                    self.tapTimes.removeAll()

                    if count >= 2 {
                        self.onDoubleTap?()
                    }
                }
            }
        }
    }

    /// 長按觸發
    private func handleLongPress() {
        // 清除 tap 記錄（避免長按後又觸發 double-tap）
        tapTimes.removeAll()
        tapActionTimer?.invalidate()

        if isRecording {
            // 錄音中長按 → 結束當前錄音 + 開始新錄音
            // 先觸發 singleTap（結束），再觸發 longPressStart（開始新的）
            onSingleTap?()
            // 短暫延遲確保前一個錄音已結束
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.onLongPressStart?()
            }
        } else {
            // 非錄音中長按 → 開始錄音
            onLongPressStart?()
        }
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
