#!/usr/bin/env python3
# OmniChat Audio Provider (mlx-whisper 轉錄 + litert-lm 回應)
# stdin: JSON { "messages": [...], "model": "...", "audioPath": "/path/to/audio.wav" }
# stdout: 逐行輸出回應文字

import sys
import json
import os
import subprocess
import mlx_whisper

# 確保 Homebrew 路徑在 PATH 中（App 的 shell 環境可能沒有）
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")

# 讀取 stdin JSON
input_data = json.loads(sys.stdin.read())
audio_path = input_data.get("audioPath", "")
messages_raw = input_data.get("messages", [])

# 取得 system prompt 和歷史訊息
system_prompt = ""
history = []
for msg in messages_raw:
    if msg["role"] == "system":
        system_prompt = msg["content"]
    elif msg["content"] != "[Voice Input]":
        history.append(msg)

# 用 mlx-whisper 轉錄音訊
transcript = ""
if audio_path:
    result = mlx_whisper.transcribe(
        audio_path,
        path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
        language="zh",  # 中文為主，英文夾雜也能正確轉錄
    )
    transcript = result.get("text", "").strip()

if not transcript:
    print("（無法辨識語音）", flush=True)
    sys.exit(0)

# 輸出轉錄結果（讓使用者看到說了什麼）
print(f"[轉錄] {transcript}", flush=True)

# 組合 prompt 送給 litert-lm
prompt_parts = []
if system_prompt:
    prompt_parts.append(f"System: {system_prompt}")
for msg in history:
    role = "User" if msg["role"] == "user" else "Assistant"
    prompt_parts.append(f"{role}: {msg['content']}")
prompt_parts.append(f"User: {transcript}")
prompt_parts.append("Assistant:")

prompt = "\n\n".join(prompt_parts)

# 呼叫本地 litert-lm 產生回應（即時串流輸出）
proc = subprocess.Popen(
    [
        "/Users/taishen/.local/bin/litert-lm",
        "run",
        "/Users/taishen/active/ai_env/gemma-4-E4B-it.litertlm",
        "-b", "gpu",
        "--prompt", prompt,
    ],
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,  # 行緩衝
)

# 逐行讀取並即時輸出，過濾 <pad> 與 Markdown 星號
for line in proc.stdout:
    cleaned = line.replace("<pad>", "").replace("*", "")
    if cleaned.strip():
        print(cleaned, end="", flush=True)

proc.wait()
