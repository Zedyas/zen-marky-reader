#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

if (( $# > 1 )) || [[ -n "${1:-}" && "$1" != '--universal' ]]; then
  print -u2 'Usage: scripts/build-app.sh [--universal]'
  exit 1
fi

if [[ "${1:-}" == '--universal' ]]; then
  ARM_TRIPLE='arm64-apple-macosx14.0'
  INTEL_TRIPLE='x86_64-apple-macosx14.0'
  ARM_SCRATCH="$PWD/.build/arm64"
  INTEL_SCRATCH="$PWD/.build/x86_64"
  swift build -c release --scratch-path "$ARM_SCRATCH" --triple "$ARM_TRIPLE"
  BUILD_DIR="$(swift build -c release --scratch-path "$ARM_SCRATCH" --triple "$ARM_TRIPLE" --show-bin-path)"
  swift build -c release --scratch-path "$INTEL_SCRATCH" --triple "$INTEL_TRIPLE"
  INTEL_BUILD_DIR="$(swift build -c release --scratch-path "$INTEL_SCRATCH" --triple "$INTEL_TRIPLE" --show-bin-path)"
else
  swift build -c release
  BUILD_DIR="$(swift build -c release --show-bin-path)"
fi

APP="$PWD/dist/Zen Marky Reader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${1:-}" == '--universal' ]]; then
  lipo -create "$BUILD_DIR/ZenMarky" "$INTEL_BUILD_DIR/ZenMarky" -output "$APP/Contents/MacOS/ZenMarky"
else
  cp "$BUILD_DIR/ZenMarky" "$APP/Contents/MacOS/ZenMarky"
fi
cp Info.plist "$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
  if [[ ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 'APP_VERSION must be a three-part numeric version.'
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$APP/Contents/Info.plist"
fi
RESOURCE_BUNDLE="$(find "$BUILD_DIR" -maxdepth 1 -name '*.bundle' -type d -print -quit)"
if [[ -z "$RESOURCE_BUNDLE" ]]; then
  print -u2 'Missing Swift resource bundle.'
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/${RESOURCE_BUNDLE:t}"
swift scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
print "Built $APP"
