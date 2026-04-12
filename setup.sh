#!/bin/bash
# OmniChat 初始設定腳本

CONFIG_DIR="$HOME/.config/omnichat"
PROVIDERS_DIR="$CONFIG_DIR/providers"

mkdir -p "$PROVIDERS_DIR"

# 檢查 jq 是否安裝
if ! command -v jq &> /dev/null; then
    echo "正在安裝 jq..."
    brew install jq
fi

# 寫入 config.json
cat > "$CONFIG_DIR/config.json" << 'CONFIGEOF'
{
  "appearance": "system",
  "defaultMode": 0,
  "hideAfterSend": false,
  "theme": {
    "backgroundColor": "#1e1e2e",
    "backgroundOpacity": 0.8,
    "backgroundBlur": 20,
    "sidebarColor": "#181825",
    "userBubbleColor": "#3b82f6",
    "userTextColor": "#ffffff",
    "assistantTextColor": "#cdd6f4",
    "inputBackgroundColor": "#313244",
    "inputTextColor": "#cdd6f4",
    "accentColor": "#89b4fa"
  },
  "defaultProvider": "litert",
  "hotkey": {
    "doubleTapInterval": 300,
    "doubleTapKey": "rightOption",
    "longPressThreshold": 500
  },
  "modes": [
    {
      "name": "General",
      "systemPrompt": "You are a helpful assistant."
    },
    {
      "name": "Coding",
      "systemPrompt": "You are an expert programmer. Provide concise code solutions with explanations."
    }
  ],
  "providers": {
    "ollama": {
      "command": "~/.config/omnichat/providers/ollama.sh",
      "defaultModel": "llama3.1:latest",
      "models": ["llama3.1:latest"]
    },
    "litert": {
      "command": "~/.config/omnichat/providers/litert.sh",
      "defaultModel": "gemma-4-E4B",
      "models": ["gemma-4-E4B"]
    }
  },
  "socketPath": "~/.config/omnichat/omnichat.sock"
}
CONFIGEOF

# Ollama provider（用於 llama3.1）
cat > "$PROVIDERS_DIR/ollama.sh" << 'SCRIPTEOF'
#!/bin/bash
# OmniChat Ollama Provider
INPUT=$(cat)
MODEL=$(echo "$INPUT" | jq -r '.model')
MESSAGES=$(echo "$INPUT" | jq -c '.messages')

curl -s --no-buffer "http://localhost:11434/api/chat" \
  -d "{\"model\": \"$MODEL\", \"messages\": $MESSAGES, \"stream\": true}" \
  | while IFS= read -r line; do
    echo "$line" | jq -j '.message.content // empty'
  done
SCRIPTEOF

# LiteRT provider（用於 gemma4）
cat > "$PROVIDERS_DIR/litert.sh" << 'SCRIPTEOF'
#!/bin/bash
# OmniChat LiteRT-LM Provider (gemma4)
INPUT=$(cat)
MESSAGES=$(echo "$INPUT" | jq -c '.messages')

# 把 messages 組合成單一 prompt
PROMPT=$(echo "$INPUT" | jq -r '
  .messages | map(
    if .role == "system" then "System: " + .content
    elif .role == "user" then "User: " + .content
    elif .role == "assistant" then "Assistant: " + .content
    else .content
    end
  ) | join("\n\n")
')

# 過濾 <pad> token，把逐 token 輸出合併為連續文字
/Users/taishen/.local/bin/litert-lm run /Users/taishen/active/ai_env/gemma-4-E4B-it.litertlm -b gpu --prompt "$PROMPT" 2>/dev/null \
  | sed 's/<pad>//g' \
  | tr -d '\n' \
  | sed 's/$/\n/'
SCRIPTEOF

chmod +x "$PROVIDERS_DIR/ollama.sh"
chmod +x "$PROVIDERS_DIR/litert.sh"

echo "✅ 設定完成"
echo ""
echo "Providers:"
echo "  ollama  → llama3.1:latest (需要 ollama serve 運行中)"
echo "  litert  → gemma-4-E4B"
echo ""
echo "測試："
echo "  echo '{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"model\":\"llama3.1:latest\"}' | ~/.config/omnichat/providers/ollama.sh"
