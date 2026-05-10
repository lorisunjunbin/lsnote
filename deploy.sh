#!/bin/bash

set -e

BUILD_TYPE="release"
if [[ "$1" == "--debug" || "$1" == "-d" ]]; then
    BUILD_TYPE="debug"
fi

echo "=== lsnote Deploy Script ==="
echo "Build type: $BUILD_TYPE"
echo ""

# Check adb available
if ! command -v adb &> /dev/null; then
    echo "❌ adb not found."
    echo ""
    echo "Install Android SDK Platform Tools:"
    echo "  brew install android-platform-tools"
    echo ""
    echo "Or download from:"
    echo "  https://developer.android.com/tools/releases/platform-tools"
    exit 1
fi

# Check device connected
DEVICE_COUNT=$(adb devices | grep -c -w "device$" || true)
if [[ "$DEVICE_COUNT" -eq 0 ]]; then
    echo "❌ No device connected or USB debugging not enabled."
    echo ""
    echo "Checklist:"
    echo "  1. Connect phone via USB cable"
    echo "  2. Enable Developer Options:"
    echo "     Settings → About Phone → tap 'Build Number' 7 times"
    echo "  3. Enable USB Debugging:"
    echo "     Settings → Developer Options → USB Debugging → ON"
    echo "  4. Authorize this computer on phone prompt"
    echo "  5. Verify connection: adb devices"
    echo ""
    echo "If using wireless debugging:"
    echo "  adb connect <phone-ip>:5555"
    exit 1
fi

DEVICE_NAME=$(adb devices -l | grep "device " | head -1 | sed 's/.*model:\([^ ]*\).*/\1/')
echo "✓ Device connected: ${DEVICE_NAME:-unknown}"
echo ""

# Build
echo "→ Building $BUILD_TYPE APK..."
if [[ "$BUILD_TYPE" == "release" ]]; then
    flutter build apk --release --target-platform android-arm64
    APK_PATH="build/app/outputs/flutter-apk/app-release.apk"
else
    flutter build apk --debug --target-platform android-arm64
    APK_PATH="build/app/outputs/flutter-apk/app-debug.apk"
fi

if [[ ! -f "$APK_PATH" ]]; then
    echo "❌ Build failed: $APK_PATH not found"
    exit 1
fi

APK_SIZE=$(du -h "$APK_PATH" | cut -f1)
echo "✓ Build success: $APK_PATH ($APK_SIZE)"
echo ""

# Install
echo "→ Installing on device..."
adb install -r "$APK_PATH"
echo ""
echo "✓ Done! App installed successfully."
