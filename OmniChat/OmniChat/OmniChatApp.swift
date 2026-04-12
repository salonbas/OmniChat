// OmniChatApp.swift
// OmniChat
// App 進入點

import SwiftUI
import SwiftData

@main
struct OmniChatApp: App {
    @NSApplicationDelegateAdaptor(OmniChatAppDelegate.self) var appDelegate

    var body: some Scene {
        // 實際視窗由 AppDelegate 建立，這裡只需要一個空的 Scene
        Settings {
            EmptyView()
        }
        .commands {
            // 攔截 Cmd+N，改為開新視窗
            CommandGroup(replacing: .newItem) {
                Button("新視窗") {
                    appDelegate.openNewWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
