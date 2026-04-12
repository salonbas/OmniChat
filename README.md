# OmniChat

A CLI-first macOS AI chatbot. Bring your own model — OmniChat doesn't care if it's Ollama, Claude, Gemini, or a custom binary. If it reads JSON from stdin and writes text to stdout, it works.

## Why OmniChat?

- **CLI-first** — every feature works from the terminal
- **Model agnostic** — connect any LLM via shell scripts
- **Unix philosophy** — pipe, redirect, compose with other tools
- **Lightweight GUI** — native macOS chat window when you want it
- **Zero lock-in** — config is a JSON file, providers are shell scripts

## Install

### Homebrew (recommended)

```bash
brew tap salonbas/omnichat
brew install --cask omnichat
```

This installs `OmniChat.app` and the `omni` CLI.

### Manual

1. Download the latest `.dmg` from [Releases](https://github.com/salonbas/OmniChat/releases)
2. Drag `OmniChat.app` to `/Applications`
3. Create the CLI symlink:
   ```bash
   sudo ln -sf /Applications/OmniChat.app/Contents/MacOS/omni /usr/local/bin/omni
   ```
4. Remove quarantine:
   ```bash
   xattr -cr /Applications/OmniChat.app
   ```

## Quick Start

```bash
# Talk to your default model
omni "What is the meaning of life?"

# Use a specific model
omni -m claude "Explain monads"

# Silent mode — no GUI, pure stdout
omni --silent "List 5 random words" | sort

# Pipe content in
cat error.log | omni --silent "What went wrong?"

# Save output
omni --new "Notes on 'diabolical'" > vocab/diabolical.md
```

## CLI Usage

```
omni [OPTIONS] [PROMPT]
```

### Conversation

| Command | Description |
|---------|-------------|
| `omni "prompt"` | Send to active conversation (opens GUI) |
| `omni --new "prompt"` | Create new conversation + send |
| `omni -c ID "prompt"` | Send to specific conversation |
| `omni -m MODEL "prompt"` | Use specific model or provider |
| `omni -p MODE "prompt"` | Use specific mode (by index) |
| `omni --silent "prompt"` | Direct script call, no GUI |

### Window Control

| Command | Description |
|---------|-------------|
| `omni --new-window` | Open new window |
| `omni --new` | Create new conversation |
| `omni --toggle` | Show/hide window |
| `omni --clear` | Clear active conversation |
| `omni --clear -c ID` | Clear specific conversation |

### Query

| Command | Description |
|---------|-------------|
| `omni --list-models` | List available models |
| `omni --list-modes` | List modes with index |
| `omni --history` | List conversations with IDs |
| `omni --version` | Show version |

### Output

All commands with a prompt stream the model's response to **stdout**. Status messages go to **stderr**. This means piping and redirecting always work as expected:

```bash
omni "explain quicksort" > notes.md          # save to file
omni "list colors" | grep blue               # pipe
omni "add more" >> notes.md                  # append
CID=$(omni --new "hi" 2>&1 >/dev/null | grep conv: | cut -d: -f2)  # capture conversation ID
```

## Configuration

All configuration lives in `~/.config/omnichat/config.json`. There is no settings UI — edit the file directly.

On first run, OmniChat creates a default config with example providers.

### Config File

```json
{
  "defaultProvider": "ollama",
  "providers": {
    "ollama": {
      "command": "~/.config/omnichat/providers/ollama.sh",
      "defaultModel": "llama3.1:latest",
      "models": ["llama3.1:latest", "gemma:7b"]
    },
    "claude": {
      "command": "~/.config/omnichat/providers/claude.sh",
      "defaultModel": "claude-sonnet-4-20250514",
      "models": ["claude-sonnet-4-20250514", "claude-haiku-4-5-20251001"]
    }
  },
  "modes": [
    { "name": "General", "systemPrompt": "You are a helpful assistant." },
    { "name": "Coding", "systemPrompt": "You are an expert programmer." }
  ],
  "defaultMode": 0,
  "appearance": "system",
  "socketPath": "~/.config/omnichat/omnichat.sock",
  "hideAfterSend": false,
  "theme": {
    "backgroundColor": "#061922",
    "backgroundOpacity": 0.80,
    "backgroundBlur": 20.0,
    "sidebarColor": "#040f18",
    "userBubbleColor": "#15394E",
    "userTextColor": "#DADADA",
    "assistantTextColor": "#DADADA",
    "inputBackgroundColor": "#0a1e2a",
    "inputTextColor": "#DADADA",
    "accentColor": "#78E3FC"
  },
  "hotkey": {
    "doubleTapKey": "rightOption",
    "doubleTapInterval": 300,
    "longPressThreshold": 500
  }
}
```

### Model Resolution (`-m`)

The `-m` flag matches in this order:

1. **Provider name** — `omni -m claude "hi"` → uses claude provider's default model
2. **Model name** — `omni -m gemma:7b "hi"` → finds the provider that has this model
3. **Default** — no `-m` → uses `defaultProvider`'s `defaultModel`

### Modes (`-p`)

Modes are preset system prompts:

```bash
omni --list-modes
# 0: General (default)
# 1: Coding

omni -p 1 "Write a Python quicksort"
```

## Providers

OmniChat doesn't call any AI API directly. Instead, it delegates to **provider scripts** — any executable that follows this protocol:

**Input** (JSON via stdin):
```json
{
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello"}
  ],
  "model": "llama3.1:latest"
}
```

**Output** (text via stdout): Stream response text line by line. Exit 0 when done.

### Example: Ollama

```bash
#!/bin/bash
INPUT=$(cat)
MODEL=$(echo "$INPUT" | jq -r '.model')
MESSAGES=$(echo "$INPUT" | jq -c '.messages')

curl -s --no-buffer "http://localhost:11434/api/chat" \
  -d "{\"model\": \"$MODEL\", \"messages\": $MESSAGES, \"stream\": true}" \
  | while IFS= read -r line; do
    echo "$line" | jq -j '.message.content // empty'
  done
```

### Example: Claude

```bash
#!/bin/bash
INPUT=$(cat)
API_KEY="your-key-here"  # or use $ANTHROPIC_API_KEY
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

### Write Your Own

Any language works — Python, Go, Rust, even a compiled binary. Just follow stdin JSON → stdout text.

## Keyboard Shortcuts

| Action | Shortcut | Behavior |
|--------|----------|----------|
| Toggle Focus | Right Option × 2 | Show if hidden, hide if focused |
| Dictation | Right Option long press (>0.5s) | Trigger macOS Dictation |

## Shell Integration

```bash
# Alias for quick queries
alias ask='omni --silent'
alias code='omni --silent -p 1'

# Code review
alias review='omni --silent -p 1 "Review this code:" <'

# Raycast / Alfred
omni "$1"

# Hammerspoon
hs.execute("/usr/local/bin/omni --toggle")
```

## Requirements

- macOS 15 (Sequoia) or later
- [jq](https://jqlang.github.io/jq/) (for provider scripts)
- A model provider (Ollama, API key, etc.)

## License

[MIT](LICENSE)
