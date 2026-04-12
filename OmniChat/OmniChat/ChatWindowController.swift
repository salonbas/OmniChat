// ChatWindowController.swift
// OmniChat
// 建立透明模糊背景的聊天視窗

import AppKit
import SwiftUI
import SwiftData

final class ChatWindowController: NSWindowController {
    init(chatEngine: ChatEngine, appState: AppState, modelContainer: ModelContainer) {
        let config = appState.config
        let theme = config.theme

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // 視窗本身設為透明（SkyLight blur + backgroundColor 接手）
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // 從 config 解析背景色 RGBA
        window.backgroundColor = Self.nsColor(
            hex: theme?.backgroundColor ?? "#1e1e2e",
            alpha: theme?.backgroundOpacity ?? 0.8
        )

        window.setFrameAutosaveName("OmniChatMainWindow")
        if window.frame.origin == .zero {
            window.center()
        }

        let rootView = ContentView()
            .environment(chatEngine)
            .environment(appState)
            .modelContainer(modelContainer)

        window.contentView = NSHostingView(rootView: rootView)

        super.init(window: window)

        // 套用 SkyLight blur（需要在 super.init 後才有 windowNumber）
        if let blurRadius = theme?.backgroundBlur, blurRadius > 0 {
            Self.setSkyLightBlur(
                windowID: CGWindowID(window.windowNumber),
                radius: Int(blurRadius)
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - SkyLight Private API

    /// 用 WindowServer compositor 層對視窗加 blur，不影響內容顏色
    private static func setSkyLightBlur(windowID: CGWindowID, radius: Int) {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return }

        typealias GetConnFn = @convention(c) () -> Int32
        typealias SetBlurFn = @convention(c) (Int32, CGWindowID, Int) -> OSStatus

        guard let connSym = dlsym(handle, "SLSDefaultConnectionForThread"),
              let blurSym = dlsym(handle, "SLSSetWindowBackgroundBlurRadius") else { return }

        let getConn = unsafeBitCast(connSym, to: GetConnFn.self)
        let setBlur = unsafeBitCast(blurSym, to: SetBlurFn.self)

        _ = setBlur(getConn(), windowID, radius)
    }

    // MARK: - Helpers

    private static func nsColor(hex: String, alpha: Double) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else {
            return NSColor(white: 0.12, alpha: alpha)
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8)  & 0xFF) / 255.0
        let b = Double( value        & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: alpha)
    }
}
