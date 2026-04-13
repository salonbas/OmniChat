#!/usr/bin/env python3
"""OmniChat TTS - Kokoro-82M
從 stdin 讀取 JSON，產出音訊檔案，stdout 回傳檔案路徑

stdin JSON 格式:
{
    "text": "Hello world",
    "voice": "af_heart",
    "output_dir": "/path/to/output"
}

stdout: 音檔路徑（單行）
"""

import sys
import json
import os
import hashlib

def main():
    input_data = json.loads(sys.stdin.read())
    text = input_data["text"]
    voice = input_data.get("voice", "af_heart")
    output_dir = input_data.get("output_dir", "/tmp/omnichat_tts")

    os.makedirs(output_dir, exist_ok=True)

    # 用 text hash 作為檔名，避免重複合成相同內容
    text_hash = hashlib.md5(text.encode()).hexdigest()[:12]
    output_path = os.path.join(output_dir, f"tts_{text_hash}.wav")

    # 如果已經合成過，直接回傳
    if os.path.exists(output_path):
        print(output_path)
        return

    import torch
    from kokoro import KPipeline
    import soundfile as sf

    # 初始化 Kokoro pipeline（'a' = American English）
    pipeline = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')

    # 合成語音（inference_mode 省記憶體 + 微加速）
    with torch.inference_mode():
        generator = pipeline(text, voice=voice)

    # Kokoro 回傳 generator，合併所有 segment
    all_audio = []
    sample_rate = 24000
    for i, (gs, ps, audio) in enumerate(generator):
        all_audio.append(audio)

    if not all_audio:
        print("ERROR: No audio generated", file=sys.stderr)
        sys.exit(1)

    import numpy as np
    combined = np.concatenate(all_audio)

    # 寫入 WAV
    sf.write(output_path, combined, sample_rate)
    print(output_path)


if __name__ == "__main__":
    main()
