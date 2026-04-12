#!/bin/bash
# OmniChat CLI 測試腳本
# 測試所有 omni 指令的參數解析與基本行為

# 顏色定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# omni binary 路徑（可用第一個參數覆蓋）
OMNI="${1:-$HOME/Library/Developer/Xcode/DerivedData/OmniChat-fttqilmvkspshpdrtziafpckmemx/Build/Products/Debug/omni}"

PASS=0
FAIL=0
SKIP=0

run_test() {
    local name="$1"
    local cmd="$2"
    local expect_exit="$3"  # 0=成功, nonzero=預期失敗, skip=跳過

    if [[ "$expect_exit" == "skip" ]]; then
        echo -e "  ${YELLOW}SKIP${NC} $name"
        ((SKIP++))
        return
    fi

    echo -e "  ${CYAN}TEST${NC} $name"
    echo -e "       cmd: $cmd"

    # 加 timeout 避免 provider 卡住或 OOM（macOS 相容）
    perl -e 'alarm 15; exec @ARGV' bash -c "$cmd" >/tmp/omni_test_stdout 2>/tmp/omni_test_stderr
    exit_code=$?
    if [[ "$exit_code" -eq 142 ]]; then
        echo -e "  ${RED}TIMEOUT${NC} (15s)"
        ((FAIL++))
        echo ""
        return
    fi
    stdout=$(cat /tmp/omni_test_stdout)
    stderr=$(cat /tmp/omni_test_stderr)

    if [[ "$expect_exit" -eq 0 && "$exit_code" -eq 0 ]] || \
       [[ "$expect_exit" -ne 0 && "$exit_code" -ne 0 ]]; then
        echo -e "  ${GREEN}PASS${NC} exit=$exit_code"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC} expected exit=$expect_exit, got exit=$exit_code"
        ((FAIL++))
    fi

    if [[ -n "$stdout" ]]; then
        echo -e "       stdout: $(echo "$stdout" | head -3)"
    fi
    if [[ -n "$stderr" ]]; then
        echo -e "       stderr: $(echo "$stderr" | head -3)"
    fi
    echo ""
}

echo ""
echo "============================================"
echo " OmniChat CLI 測試"
echo " binary: $OMNI"
echo "============================================"
echo ""

if [[ ! -x "$OMNI" ]]; then
    echo -e "${RED}Error: $OMNI 不存在或不可執行${NC}"
    echo "用法: ./test_cli.sh [/path/to/omni]"
    exit 1
fi

# ── 1. 基本指令 ──
echo "── 1. 基本指令 ──"

run_test "--help" \
    "$OMNI --help" 0

run_test "--version" \
    "$OMNI --version" 0

# ── 2. 查詢指令（不需要 App）──
echo "── 2. 查詢指令（不需要 App）──"

run_test "--list-models" \
    "$OMNI --list-models" 0

run_test "--list-modes" \
    "$OMNI --list-modes" 0

# ── 3. 錯誤處理 ──
echo "── 3. 錯誤處理 ──"

run_test "無參數（應失敗）" \
    "$OMNI" 1

run_test "--silent 無 prompt（應失敗）" \
    "$OMNI --silent" 1

run_test "--silent 不存在的 model（應失敗）" \
    "$OMNI --silent -m nonexistent_model 'test'" 1

# ── 4. 參數存在性驗證（透過 --help）──
echo "── 4. 參數存在性驗證 ──"

run_test "-c / --conversation 參數存在" \
    "$OMNI --help | grep -q '\\-c'" 0

run_test "--new 參數存在" \
    "$OMNI --help | grep -q '\\-\\-new '" 0

run_test "--new-window 參數存在" \
    "$OMNI --help | grep -q '\\-\\-new-window'" 0

run_test "--toggle 參數存在" \
    "$OMNI --help | grep -q '\\-\\-toggle'" 0

run_test "--clear 參數存在" \
    "$OMNI --help | grep -q '\\-\\-clear'" 0

run_test "--silent 參數存在" \
    "$OMNI --help | grep -q '\\-\\-silent'" 0

run_test "--history 參數存在" \
    "$OMNI --help | grep -q '\\-\\-history'" 0

run_test "-m / --model 參數存在" \
    "$OMNI --help | grep -q '\\-m'" 0

run_test "-p / --mode 參數存在" \
    "$OMNI --help | grep -q '\\-p'" 0

# ── 5. IPC 指令（需要 App 運行）──
echo "── 5. IPC 指令（需要 App 運行）──"

# 用實際 connect 測試 socket，而非只檢查檔案存在
SOCK="$HOME/.config/omnichat/omnichat.sock"
SOCK_OK=false
if [[ -S "$SOCK" ]]; then
    # 嘗試真正連線（送一個空行，看是否能連上）
    if python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect('$SOCK')
    s.close()
except:
    sys.exit(1)
" 2>/dev/null; then
        SOCK_OK=true
    fi
fi

if [[ "$SOCK_OK" == "true" ]]; then
    echo -e "  ${GREEN}App 已運行且 socket 可連線${NC}，執行 IPC 測試"
    echo ""

    run_test "omni 'hello'（active 對話）" \
        "$OMNI 'hello'" 0

    run_test "omni --new 'hello'（新對話+prompt）" \
        "$OMNI --new 'hello'" 0

    run_test "omni --new（單純建立新對話）" \
        "$OMNI --new" 0

    run_test "omni --new-window（開新視窗）" \
        "$OMNI --new-window" 0

    run_test "omni --toggle" \
        "$OMNI --toggle" 0

    run_test "omni --clear（清空 active 對話）" \
        "$OMNI --clear" 0

    run_test "omni --history" \
        "$OMNI --history" 0

    run_test "omni -m ollama 'test'" \
        "$OMNI -m ollama 'test'" 0

    run_test "omni -p 1 'test'（Coding mode）" \
        "$OMNI -p 1 'test'" 0

    run_test "omni -c invalid_id 'test'（無效 ID，應失敗）" \
        "$OMNI -c invalid_id 'test'" 1

    run_test "redirect: omni --new 'say ok' > file" \
        "$OMNI --new 'say ok' > /tmp/omni_redirect_test.txt && test -s /tmp/omni_redirect_test.txt" 0
    rm -f /tmp/omni_redirect_test.txt
else
    echo -e "  ${YELLOW}App 未運行${NC}，跳過 IPC 測試"
    echo ""
    for t in "active 對話" "新對話+prompt" "單純新對話" "開新視窗" \
             "toggle" "clear" "history" "指定 model" "指定 mode" "無效 ID" "redirect"; do
        run_test "$t（需要 App）" "true" "skip"
    done
fi

# ── 6. --silent 直接呼叫腳本 ──
echo "── 6. --silent 直接呼叫腳本 ──"

PROVIDER_DIR="$HOME/.config/omnichat/providers"
if [[ -d "$PROVIDER_DIR" ]] && ls "$PROVIDER_DIR"/*.sh &>/dev/null; then
    echo -e "  ${GREEN}Provider 腳本存在${NC}"
    echo ""

    # 每次請求之間等 2 秒，避免連續呼叫造成資源壓力
    run_test "--silent 'hello'" \
        "$OMNI --silent 'say hi in one word'" 0

    sleep 2
    run_test "--silent redirect > file" \
        "$OMNI --silent 'say ok' > /tmp/omni_silent_test.txt && test -s /tmp/omni_silent_test.txt" 0

    sleep 2
    run_test "--silent pipe input" \
        "echo 'repeat: test123' | $OMNI --silent 'repeat the stdin'" 0

    sleep 2
    run_test "--silent pipe output" \
        "$OMNI --silent 'say exactly: PIPETEST' | grep -q 'PIPETEST'" 0

    # 指定 model/mode 測試（只在確認基本 silent 通過後才跑）
    if [[ "$FAIL" -eq 0 ]]; then
        sleep 2
        run_test "--silent -m ollama 'test'" \
            "$OMNI --silent -m ollama 'say ok'" 0

        sleep 2
        run_test "--silent -p 1 'test'（Coding mode）" \
            "$OMNI --silent -p 1 'say ok'" 0
    else
        echo -e "  ${YELLOW}跳過 model/mode 測試（基本 silent 有失敗）${NC}"
        echo ""
        run_test "ollama（跳過）" "true" "skip"
        run_test "coding mode（跳過）" "true" "skip"
    fi

    rm -f /tmp/omni_silent_test.txt
else
    echo -e "  ${YELLOW}Provider 腳本不存在${NC}，跳過"
    echo ""
    for t in "--silent hello" "--silent -m" "--silent -p" "--silent redirect" "--silent pipe in" "--silent pipe out"; do
        run_test "$t（需要 provider）" "true" "skip"
    done
fi

# ── 結果 ──
echo "============================================"
echo -e " 結果: ${GREEN}PASS=$PASS${NC}  ${RED}FAIL=$FAIL${NC}  ${YELLOW}SKIP=$SKIP${NC}"
echo "============================================"

rm -f /tmp/omni_test_stdout /tmp/omni_test_stderr
exit $FAIL
