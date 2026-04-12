# OmniChat — Product Requirements Document

## 1. 產品概述

**OmniChat** 是一個 CLI-first 的 macOS Chatbot，附帶輕量 GUI 作為對話介面。所有功能皆可透過 CLI 操作，GUI 僅提供基本對話視窗。

- **目標用戶**: 開發者、Power User
- **核心價值**: CLI 驅動 + Unix 哲學 + 模式化對話
- **開發策略**: CLI 先行，GUI 最小化，設定全靠 config file

## 2. 技術棧

| 項目 | 選擇 | 備註 |
|------|------|------|
| 語言 | Swift 6 | SwiftUI + AppKit 混合 |
| 最低支援版本 | macOS 15 (Sequoia) | |
| 模型串接 | 外部腳本/執行檔 | Unix 哲學，App 不內建任何 provider |
| 設定檔 | `~/.config/omnichat/config.json` | 所有設定透過檔案管理 |
| 資料持久化 | SwiftData | 對話記錄 |
| IPC 機制 | Unix Domain Socket | `~/.config/omnichat/omnichat.sock` |
| 分發 | GitHub Release + Homebrew Cask | |

## 3. 架構設計

```
┌──────────────────────────────────────────────┐
│                OmniChat.app                  │
│  ┌──────────┐ ┌──────────┐ ┌─────────────┐  │
│  │ SwiftUI  │ │  Chat    │ │   Config    │  │
│  │ (基本UI) │ │  Engine  │ │   (JSON)    │  │
│  └────┬─────┘ └────┬─────┘ └──────┬──────┘  │
│       │            │              │          │
│       │       ┌────┴─────┐        │          │
│       │       │ Process  │ stdin/stdout      │
│       │       │ Runner   ├────────────►      │
│       │       └──────────┘   外部腳本        │
│  ┌────┴───────────────────────────┴──────┐   │
│  │        UDS Server (IPC Layer)         │   │
│  └───────────────────────────────────────┘   │
│  ┌───────────────────────────────────────┐   │
│  │       SwiftData (Persistence)         │   │
│  └───────────────────────────────────────┘   │
│  ┌───────────────────────────────────────┐   │
│  │    HotkeyManager (Right Option)       │   │
│  └───────────────────────────────────────┘   │
└──────────────────────────────────────────────┘
        ▲
        │ Unix Domain Socket
        ▼
┌──────────────┐
│  omni (CLI)  │
└──────────────┘
```

### 3.1 模型串接：外部腳本模式

**App 不內建任何 API 呼叫邏輯。** 模型串接完全委託給使用者提供的腳本或執行檔。

通訊協議：
- App 以 **JSON 透過 stdin** 傳入對話內容
- 腳本以 **逐行 stdout** 串流回應（每行一個 token/chunk）
- 腳本結束 (exit 0) 代表回應完成

```
App ──stdin──► 腳本 ──stdout──► App
         JSON          逐行文字
```

stdin 傳入格式：
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi there!"},
    {"role": "user", "content": "寫一個 Python quicksort"}
  ],
  "model": "gemma:7b"
}
```

stdout 輸出：腳本逐行印出文字，App 即時顯示。

### 3.2 內建範例腳本

安裝時附帶 `~/.config/omnichat/providers/` 範例：

**ollama.sh:**
```bash
#!/bin/bash
# 從 stdin 讀取 JSON，呼叫 Ollama API，逐行輸出回應
INPUT=$(cat)
MODEL=$(echo "$INPUT" | jq -r '.model')
MESSAGES=$(echo "$INPUT" | jq -c '.messages')

curl -s --no-buffer "http://localhost:11434/api/chat" \
  -d "{\"model\": \"$MODEL\", \"messages\": $MESSAGES, \"stream\": true}" \
  | while IFS= read -r line; do
    echo "$line" | jq -r '.message.content // empty'
  done
```

**claude.sh:**
```bash
#!/bin/bash
INPUT=$(cat)
API_KEY="your-key-here"
MODEL=$(echo "$INPUT" | jq -r '.model')
MESSAGES=$(echo "$INPUT" | jq -c '[.messages[] | select(.role != "system")]')
SYSTEM=$(echo "$INPUT" | jq -r '.messages[] | select(.role == "system") | .content')

curl -s --no-buffer "https://api.anthropic.com/v1/messages" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "{\"model\": \"$MODEL\", \"max_tokens\": 4096, \"system\": \"$SYSTEM\", \"messages\": $MESSAGES, \"stream\": true}" \
  | while IFS= read -r line; do
    echo "$line" | sed -n 's/^data: //p' | jq -r '.delta.text // empty' 2>/dev/null
  done
```

使用者可以自己寫任何語言的腳本（Python, Go, 甚至一個 binary），只要符合 stdin JSON → stdout 逐行文字 的協議。

## 4. CLI 規格（核心）

### 4.1 安裝路徑

```
/usr/local/bin/omni → /Applications/OmniChat.app/Contents/MacOS/omni
```

### 4.2 指令一覽

**對話相關：**

| 指令 | 行為 |
|------|------|
| `omni "prompt"` | 發送 prompt（GUI 模式，顯示在視窗） |
| `omni -m <model> "prompt"` | 指定模型 |
| `omni -p <id> "prompt"` | 指定模式（modes 索引） |
| `omni --silent "prompt"` | 背景處理，結果輸出至 stdout |
| `omni --silent "prompt" < file` | 讀取 stdin 作為附加內容 |

**視窗控制：**

| 指令 | 行為 |
|------|------|
| `omni --new-window` | 開啟新視窗 |
| `omni --new-tab` | 開啟新分頁 |
| `omni --toggle` | 切換顯示/隱藏 |
| `omni --clear` | 清空當前對話 |

**查詢：**

| 指令 | 行為 |
|------|------|
| `omni --list-models` | 列出 config 中定義的模型 |
| `omni --list-modes` | 列出所有模式（編號 + 名稱） |
| `omni --history` | 列出對話記錄 |
| `omni --version` | 顯示版本 |
| `omni --help` | 顯示說明 |

### 4.3 IPC 協議 (JSON over UDS)

```json
// CLI → App
{ "action": "send_prompt", "prompt": "...", "model": "gemma", "mode": 0, "silent": false, "stdin": "" }
{ "action": "toggle" }
{ "action": "new_window" }
{ "action": "new_tab" }
{ "action": "clear" }
{ "action": "list_models" }
{ "action": "list_modes" }
{ "action": "history" }

// App → CLI (silent streaming)
{"status": "streaming", "chunk": "..."}
{"status": "done", "model_used": "gemma:7b"}

// App → CLI (non-silent)
{"status": "ok", "message": "Prompt sent to window"}

// App → CLI (query results)
{"status": "ok", "data": [...]}
```

## 5. Config 規格

`~/.config/omnichat/config.json`（唯一設定方式，無 GUI 設定介面）：

```json
{
  "defaultProvider": "ollama",
  "providers": {
    "ollama": {
      "command": "~/.config/omnichat/providers/ollama.sh",
      "defaultModel": "gemma:7b",
      "models": ["gemma:7b", "llama3:8b", "codellama:7b"]
    },
    "claude": {
      "command": "~/.config/omnichat/providers/claude.sh",
      "defaultModel": "claude-sonnet-4-20250514",
      "models": ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001"]
    },
    "gemini": {
      "command": "~/.config/omnichat/providers/gemini.sh",
      "defaultModel": "gemini-2.5-flash",
      "models": ["gemini-2.5-flash", "gemini-2.5-pro"]
    }
  },
  "modes": [
    { "name": "General", "systemPrompt": "You are a helpful assistant." },
    { "name": "Coding", "systemPrompt": "You are an expert programmer." },
    { "name": "Language", "systemPrompt": "You are a language tutor." },
    { "name": "Learning", "systemPrompt": "You are a patient teacher." }
  ],
  "defaultMode": 0,
  "appearance": "system",
  "socketPath": "~/.config/omnichat/omnichat.sock",
  "hotkey": {
    "doubleTapKey": "rightOption",
    "doubleTapInterval": 300,
    "longPressThreshold": 500
  }
}
```

`-m` 的解析邏輯：
- `omni -m gemma:7b "..."` → 在所有 providers 中找到包含此 model 的 provider，用其 command
- `omni -m claude "..."` → match provider name，用其 defaultModel
- 不指定 → 用 defaultProvider 的 defaultModel

## 6. 模式系統

```bash
omni --list-modes
# 0: General
# 1: Coding
# 2: Language
# 3: Learning

omni -p 1 "寫一個 Python quicksort"
omni -m claude -p 2 "How to say 'thank you' in Japanese?"
```

## 7. GUI 功能（最小化）

- **聊天視窗**: 氣泡對話，Markdown 渲染 + code highlighting
- **Streaming**: 逐 token 顯示
- **輸入框**: Shift+Enter 換行, Enter 送出
- **模型/模式**: 頂部下拉選單切換
- **側邊欄**: 對話記錄列表
- **多視窗/分頁**: 原生 macOS 標籤列
- **無設定頁面**

## 8. 快捷鍵（App 內建，非 CLI）

| 操作 | 快捷鍵 | 行為 |
|------|--------|------|
| Toggle Focus | Right Option × 2 | 未 focus → 顯示；已 focus → 隱藏 |
| 語音輸入 | Right Option 長按 (>0.5s) | 觸發 macOS Dictation |

實作：`CGEvent.tapCreate` 監聽 keyCode 61，需 Accessibility 權限。

## 9. 資料模型 (SwiftData)

```swift
@Model class Conversation {
    var id: UUID
    var title: String
    var modeIndex: Int
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade) var messages: [Message]
}

@Model class Message {
    var id: UUID
    var role: String       // "user" | "assistant"
    var content: String
    var model: String?
    var createdAt: Date
    var conversation: Conversation?
}
```

## 10. 開發階段

| Phase | 內容 | 產出 |
|-------|------|------|
| **P0** | CLI 骨架 + 外部腳本呼叫 + `--silent` | Terminal 可對話 |
| **P1** | App + UDS Server + CLI↔App IPC | `omni "prompt"` 顯示在 GUI |
| **P2** | 模式系統 + `-m` 模型解析 + SwiftData | 完整 CLI 功能 |
| **P3** | GUI 聊天介面（最小化） | 可用的對話 UI |
| **P4** | Global Hotkey (Right Option) | Toggle + 語音輸入 |
| **P5** | Homebrew Cask 打包 + 範例腳本 | 可分發 |

## 11. 專案結構

```
OmniChat/
├── OmniChat.xcodeproj
├── OmniChat/                      # App Target
│   ├── OmniChatApp.swift
│   ├── AppDelegate.swift
│   ├── Models/
│   │   ├── Conversation.swift
│   │   ├── Message.swift
│   │   └── AppConfig.swift
│   ├── Views/
│   │   ├── ChatView.swift
│   │   ├── MessageBubble.swift
│   │   ├── SidebarView.swift
│   │   └── InputView.swift
│   ├── Services/
│   │   ├── ChatEngine.swift       # 呼叫外部腳本
│   │   ├── UDSServer.swift
│   │   └── HotkeyManager.swift
│   └── Helpers/
│       └── MarkdownRenderer.swift
├── omni/                          # CLI Target
│   ├── main.swift
│   ├── Commands/
│   ├── IPC/
│   └── Helpers/
└── Shared/
    └── IPCProtocol.swift
```

## 12. 部署

### 簽名
Development 簽名（免付費）。用戶需執行：
```bash
xattr -cr /Applications/OmniChat.app
```

### Homebrew Cask
```ruby
cask "omnichat" do
  version "0.1.0"
  sha256 "..."
  url "https://github.com/salonbas/OmniChat/releases/download/v#{version}/OmniChat-#{version}.dmg"
  name "OmniChat"
  homepage "https://github.com/salonbas/OmniChat"
  app "OmniChat.app"
  binary "#{appdir}/OmniChat.app/Contents/MacOS/omni", target: "omni"
  zap trash: "~/.config/omnichat"
end
```

## 13. 自動化整合範例

```bash
# Raycast
omni "$1"

# Hammerspoon
hs.execute("/usr/local/bin/omni --toggle")

# Shell alias
alias ask='omni --silent'
alias code-review='omni --silent -p 1 "Review:" < '
```
