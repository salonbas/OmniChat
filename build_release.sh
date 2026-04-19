#!/bin/bash
set -e

ORBSTACK_PATH="/Users/taishen/OrbStack/docker/containers/claude-env/home/taishen/workspace/OmniChat"
BUILD_DIR="/tmp/OmniChat-build"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

echo "==> Copying project to local path..."
rm -rf "$BUILD_DIR"
cp -R "$ORBSTACK_PATH" "$BUILD_DIR"
cd "$BUILD_DIR/OmniChat"

echo "==> Cleaning..."
xcodebuild clean -scheme OmniChat -configuration Release

echo "==> Building OmniChat.app..."
xcodebuild build -scheme OmniChat -configuration Release -arch arm64

echo "==> Building omni CLI..."
xcodebuild build -scheme omni -configuration Release -arch arm64

RELEASE_PATH=$(find "$DERIVED_DATA" -path "*/Release/OmniChat.app" -maxdepth 5 2>/dev/null | head -1)
OMNI_PATH=$(find "$DERIVED_DATA" -path "*/Release/omni" -not -path "*.app*" -maxdepth 5 2>/dev/null | head -1)

if [ -z "$RELEASE_PATH" ]; then
  echo "Build failed: OmniChat.app not found"
  exit 1
fi
if [ -z "$OMNI_PATH" ]; then
  echo "Build failed: omni CLI not found"
  exit 1
fi

echo "==> Found app at: $RELEASE_PATH"
echo "==> Found CLI at: $OMNI_PATH"

echo "==> Zipping..."
STAGING="/tmp/OmniChat-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$RELEASE_PATH" "$STAGING/"
cp "$OMNI_PATH" "$STAGING/"
cd "$STAGING"
zip -r /tmp/OmniChat-0.3.0-macOS.zip OmniChat.app omni

echo "==> Deleting old release asset..."
TOKEN=$(cat /Users/taishen/ClaudeCode-container/.github_token)
# 刪除舊的 asset
curl -s -X DELETE \
  -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/salonbas/OmniChat/releases/assets/399396745"

echo "==> Uploading to GitHub release..."
curl -X POST \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @/tmp/OmniChat-0.3.0-macOS.zip \
  "https://uploads.github.com/repos/salonbas/OmniChat/releases/310718905/assets?name=OmniChat-0.3.0-macOS.zip"

echo ""
echo "==> Cleaning up..."
rm -rf "$BUILD_DIR" "$STAGING"

echo "✓ Done!"
