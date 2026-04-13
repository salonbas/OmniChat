#!/bin/bash
# OmniChat Voice Provider (Gemma 4 Multimodal)
INPUT=$(cat)
AUDIO_PATH=$(echo "$INPUT" | jq -r '.audioPath // empty')
PROMPT=$(echo "$INPUT" | jq -r '
  .messages | map(
    if .role == "system" then "System: " + .content
    elif .role == "user" then "User: " + .content
    elif .role == "assistant" then "Assistant: " + .content
    else .content
    end
  ) | join("\n\n")
')

if [ -n "$AUDIO_PATH" ] && [ -f "$AUDIO_PATH" ]; then
    /Users/taishen/.local/bin/litert-lm run \
        /Users/taishen/active/ai_env/gemma-4-E4B-it.litertlm \
        -b gpu --audio "$AUDIO_PATH" --prompt "$PROMPT" 2>/dev/null \
        | sed 's/<pad>//g'
else
    /Users/taishen/.local/bin/litert-lm run \
        /Users/taishen/active/ai_env/gemma-4-E4B-it.litertlm \
        -b gpu --prompt "$PROMPT" 2>/dev/null \
        | sed 's/<pad>//g'
fi
