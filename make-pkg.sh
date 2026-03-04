#!/bin/sh
set -e

VERSION=${1:-"1.0.0"}

echo "Building FactorialWidget $VERSION..."

xcodebuild \
  -project FactorialWidget.xcodeproj \
  -scheme FactorialWidget \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath build \
  build

echo "Packaging..."

mkdir -p /tmp/pkg-root/Applications
cp -R "build/Build/Products/Release/FactorialWidget.app" /tmp/pkg-root/Applications/

pkgbuild \
  --root /tmp/pkg-root \
  --identifier com.noma.FactorialWidget \
  --version "$VERSION" \
  --install-location / \
  "FactorialWidget-$VERSION.pkg"

rm -rf /tmp/pkg-root

echo "Done: FactorialWidget-$VERSION.pkg"
