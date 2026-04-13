#!/bin/bash
# OmniChat TTS 設定腳本 - Kokoro-82M (uv + persistent venv)

set -e

TTS_DIR="$HOME/.config/omnichat/tts"
VENV_DIR="$TTS_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== OmniChat TTS Setup (Kokoro-82M) ==="

# 檢查 uv
if ! command -v uv &> /dev/null; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# 建立目錄
mkdir -p "$TTS_DIR"
mkdir -p "$HOME/.config/omnichat/tts_output"
mkdir -p "$HOME/.config/omnichat/voice_tmp"

# 建立持久 venv（用 uv，比 pip 快 10x）
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating venv with Python 3.12..."
    uv venv --python 3.12 "$VENV_DIR"
fi

echo "Installing dependencies..."
uv pip install --python "$VENV_DIR/bin/python3" \
    kokoro soundfile numpy "misaki[en]" torch torchaudio

# 安裝 spacy model（持久保存在 venv 裡）
echo "Installing spacy English model..."
"$VENV_DIR/bin/python3" -m spacy download en_core_web_sm 2>/dev/null || true

# 複製 TTS 腳本
cp "$SCRIPT_DIR/scripts/kokoro_tts.py" "$TTS_DIR/kokoro_tts.py"
chmod +x "$TTS_DIR/kokoro_tts.py"

# 建立 wrapper script（直接用 venv 的 Python）
cat > "$TTS_DIR/kokoro_tts.sh" << WRAPPEREOF
#!/bin/bash
exec "$VENV_DIR/bin/python3" "$TTS_DIR/kokoro_tts.py"
WRAPPEREOF
chmod +x "$TTS_DIR/kokoro_tts.sh"

echo ""
echo "TTS setup complete!"
echo "  Script: $TTS_DIR/kokoro_tts.sh"
echo "  Venv:   $VENV_DIR"
echo ""
echo "Test:"
echo "  echo '{\"text\":\"Hello world\",\"output_dir\":\"/tmp/omnichat_tts\"}' | $TTS_DIR/kokoro_tts.sh"
