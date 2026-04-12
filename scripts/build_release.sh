#!/bin/bash
# 建置 Release 版本並打包
# 在 mac 上執行（非 container）

set -e

VERSION="${1:-0.1.0}"
BUILD_DIR="/tmp/OmniChat-release"
OUTPUT_DIR="$HOME/Desktop/OmniChat-release"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)/OmniChat"

echo -e "\033[0;36m=== OmniChat Release Build v${VERSION} ===\033[0m"

# 清理
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# 建置 OmniChat.app（Release）
echo -e "\033[0;36m建置 OmniChat.app...\033[0m"
xcodebuild -project "$PROJECT_DIR/OmniChat.xcodeproj" \
    -scheme "OmniChat" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    -destination "generic/platform=macOS" \
    ONLY_ACTIVE_ARCH=NO \
    clean build 2>&1 | tail -5

# 建置 omni CLI（Release）
echo -e "\033[0;36m建置 omni CLI...\033[0m"
xcodebuild -project "$PROJECT_DIR/OmniChat.xcodeproj" \
    -scheme "omni" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    -destination "generic/platform=macOS" \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | tail -5

# 找到產物
APP_PATH=$(find "$BUILD_DIR/derived" -name "OmniChat.app" -type d | head -1)
CLI_PATH=$(find "$BUILD_DIR/derived" -name "omni" -type f -perm +111 | grep -v '.app' | head -1)

if [[ -z "$APP_PATH" || -z "$CLI_PATH" ]]; then
    echo -e "\033[0;31m找不到建置產物\033[0m"
    echo "APP: $APP_PATH"
    echo "CLI: $CLI_PATH"
    exit 1
fi

echo -e "\033[0;32mAPP: $APP_PATH\033[0m"
echo -e "\033[0;32mCLI: $CLI_PATH\033[0m"

# 打包
STAGING="$BUILD_DIR/staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
cp "$CLI_PATH" "$STAGING/"

# 建立 zip
ZIP_NAME="OmniChat-${VERSION}-macOS.zip"
cd "$STAGING"
zip -r -y "$OUTPUT_DIR/$ZIP_NAME" OmniChat.app omni

# 計算 sha256
SHA=$(shasum -a 256 "$OUTPUT_DIR/$ZIP_NAME" | awk '{print $1}')

echo ""
echo -e "\033[0;32m=== 完成 ===\033[0m"
echo "輸出: $OUTPUT_DIR/$ZIP_NAME"
echo "SHA256: $SHA"
echo ""
echo "下一步："
echo "  1. 在 GitHub 建立 Release tag v${VERSION}"
echo "  2. 上傳 $ZIP_NAME"
echo "  3. 更新 homebrew-omnichat Cask 的 sha256"

# 寫入資訊供後續使用
cat > "$OUTPUT_DIR/release_info.txt" << INFO
VERSION=$VERSION
ZIP=$ZIP_NAME
SHA256=$SHA
INFO
