// HotkeyManager.swift
// OmniChat
// 監聽 Right Option 鍵：
// - 雙擊: toggle focus

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

    // 設定值
    private var multiTapInterval: TimeInterval = 0.35  // 多擊間隔（秒）

    // 回呼
    var onDoubleTap: (() -> Void)?   // 雙擊: toggle

    func start(config: AppConfig) {
        if let hotkey = config.hotkey {
            multiTapInterval = Double(hotkey.doubleTapInterval) / 1000.0
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
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Private

    private nonisolated func handleFlagsChangedSync(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 61 else { return }  // Right Option

        let flags = event.flags
        let isDown = flags.contains(.maskAlternate)

        Task { @MainActor in
            if isDown {
                self.handleKeyDown()
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                self.handleKeyUp(time: now)
            }
        }
    }

    private func handleKeyDown() {
        // 取消 tap action timer（還在等待更多 tap）
        tapActionTimer?.invalidate()
    }

    private func handleKeyUp(time: TimeInterval) {
        // 記錄這次 tap
        // 清除過期的 tap
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

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
