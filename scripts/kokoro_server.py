#!/usr/bin/env python3
"""OmniChat TTS Server - Kokoro-82M 常駐 HTTP 服務
模型啟動時載入一次，之後每次合成只需幾百毫秒

POST /synthesize
  Body: {"text": "Hello", "voice": "af_heart", "speed": 1.0, "output_dir": "/path"}
  Response: {"path": "/path/to/tts_xxxx.wav"}

GET /health
  Response: {"status": "ok"}

POST /shutdown
  關閉 server
"""

import sys
import os
import json
import hashlib
import signal
from http.server import HTTPServer, BaseHTTPRequestHandler

# 啟動時載入模型
print("Kokoro TTS Server: 載入模型中...", file=sys.stderr, flush=True)

import torch
import numpy as np
import soundfile as sf
from kokoro import KPipeline

pipeline = KPipeline(lang_code='a', repo_id='hexgrad/Kokoro-82M')
print("Kokoro TTS Server: 模型載入完成", file=sys.stderr, flush=True)

DEFAULT_OUTPUT_DIR = os.path.expanduser("~/.config/omnichat/tts_output")


class TTSHandler(BaseHTTPRequestHandler):
    """處理 TTS 請求"""

    def log_message(self, format, *args):
        # 靜音 HTTP log
        pass

    def do_GET(self):
        if self.path == "/health":
            self._respond(200, {"status": "ok"})
        else:
            self._respond(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/synthesize":
            self._handle_synthesize()
        elif self.path == "/shutdown":
            self._respond(200, {"status": "shutting down"})
            # 延遲關閉，讓回應先送出
            import threading
            threading.Thread(target=lambda: os._exit(0)).start()
        else:
            self._respond(404, {"error": "not found"})

    def _handle_synthesize(self):
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            data = json.loads(body)

            text = data.get("text", "").strip()
            if not text:
                self._respond(400, {"error": "empty text"})
                return

            voice = data.get("voice", "af_heart")
            speed = data.get("speed", 1.0)
            output_dir = data.get("output_dir", DEFAULT_OUTPUT_DIR)
            os.makedirs(output_dir, exist_ok=True)

            # 用 text + voice + speed 的 hash 作為檔名
            cache_key = f"{text}_{voice}_{speed}"
            text_hash = hashlib.md5(cache_key.encode()).hexdigest()[:12]
            output_path = os.path.join(output_dir, f"tts_{text_hash}.wav")

            # 快取命中
            if os.path.exists(output_path):
                self._respond(200, {"path": output_path})
                return

            # 合成語音
            with torch.inference_mode():
                generator = pipeline(text, voice=voice, speed=speed)

            all_audio = []
            for _, _, audio in generator:
                all_audio.append(audio)

            if not all_audio:
                self._respond(500, {"error": "no audio generated"})
                return

            combined = np.concatenate(all_audio)
            sf.write(output_path, combined, 24000)

            self._respond(200, {"path": output_path})

        except Exception as e:
            self._respond(500, {"error": str(e)})

    def _respond(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19876

    # 優雅關閉
    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    signal.signal(signal.SIGINT, lambda *_: os._exit(0))

    server = HTTPServer(("127.0.0.1", port), TTSHandler)
    print(f"Kokoro TTS Server: 啟動於 http://127.0.0.1:{port}", file=sys.stderr, flush=True)

    # 通知啟動完成（stdout 寫 ready，讓 Swift 端知道）
    print("ready", flush=True)

    server.serve_forever()


if __name__ == "__main__":
    main()
