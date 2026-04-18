#!/bin/bash
# OmniChat Audio Provider (whisper-cli 轉錄 + litert-lm 回應)
# stdin: JSON { "messages": [...], "model": "...", "audioPath": "/path/to/audio.wav" }
# stdout: 逐行輸出回應文字

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WHISPER_MODEL="$HOME/.config/omnichat/models/ggml-large-v3-turbo.bin"
LITERT_BIN="$HOME/.local/bin/litert-lm"
LITERT_MODEL="$HOME/active/ai_env/gemma-4-E4B-it.litertlm"

# 讀取 stdin JSON
INPUT=$(cat)
AUDIO_PATH=$(echo "$INPUT" | jq -r '.audioPath // empty')
MESSAGES=$(echo "$INPUT" | jq -c '.messages')

if [ -z "$AUDIO_PATH" ] || [ ! -f "$AUDIO_PATH" ]; then
    echo "（無法辨識語音：找不到音訊檔案）"
    exit 0
fi

# 用 whisper-cli 轉錄音訊（Metal GPU 加速，中文為主，保留英文原文）
TRANSCRIPT=$(whisper-cli -m "$WHISPER_MODEL" -f "$AUDIO_PATH" -l zh --prompt "以下是中英文混雜的對話，保留英文原文不翻譯。Hello, 你好, this is a test, 這是測試。" --no-timestamps -np 2>/dev/null | sed '/^$/d' | tr -s ' ')

if [ -z "$TRANSCRIPT" ]; then
    echo "（無法辨識語音）"
    exit 0
fi

# 輸出轉錄結果
echo "[轉錄] $TRANSCRIPT"

# 組合 prompt
SYSTEM_PROMPT=$(echo "$MESSAGES" | jq -r '.[] | select(.role == "system") | .content' | head -1)
HISTORY=$(echo "$MESSAGES" | jq -r '.[] | select(.role != "system" and .content != "[Voice Input]") | (if .role == "user" then "User" else "Assistant" end) + ": " + .content')

# TTS 開啟時，加上英文回覆指示（因為 Kokoro TTS 只支援英文）
TTS_ENABLED=$(echo "$INPUT" | jq -r '.ttsEnabled // false')
if [ "$TTS_ENABLED" = "true" ]; then
    SYSTEM_PROMPT="${SYSTEM_PROMPT} Always respond in English, even if the user speaks Chinese."
fi

PROMPT=""
[ -n "$SYSTEM_PROMPT" ] && PROMPT="System: ${SYSTEM_PROMPT}"$'\n\n'
[ -n "$HISTORY" ] && PROMPT="${PROMPT}${HISTORY}"$'\n\n'
PROMPT="${PROMPT}User: ${TRANSCRIPT}"$'\n\n'"Assistant:"

# 呼叫 litert-lm 產生回應（即時串流輸出，過濾 <pad>）
"$LITERT_BIN" run "$LITERT_MODEL" -b gpu --prompt "$PROMPT" 2>/dev/null | sed -u 's/<pad>//g'
