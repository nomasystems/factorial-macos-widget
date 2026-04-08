#!/bin/bash
set -e

APP="FactorialWidget"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🛑 Stopping running instance..."
killall "$APP" 2>/dev/null || true
sleep 1

echo "🔨 Building..."
xcodebuild \
  -project "$PROJECT_DIR/${APP}.xcodeproj" \
  -scheme "$APP" \
  -configuration Debug \
  build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10

BUILD_STATUS=${PIPESTATUS[0]}
if [ $BUILD_STATUS -ne 0 ]; then
  echo "❌ Build failed"
  exit 1
fi

DERIVED=$(find ~/Library/Developer/Xcode/DerivedData/${APP}-* \
  -name "${APP}.app" -path "*/Debug/*" ! -path "*/Index*" 2>/dev/null \
  | sort -t/ -k1 | tail -1)

if [ -z "$DERIVED" ]; then
  echo "❌ No .app found after build"
  exit 1
fi

echo "🚀 Launching $DERIVED"
open "$DERIVED"
