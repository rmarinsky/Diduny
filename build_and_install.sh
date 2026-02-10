#!/bin/bash

# Build Diduny DEV and install to /Applications
# This script builds the development version with "Diduny DEV" name

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT_NAME="Diduny"
SCHEME="Diduny DEV"
CONFIG="Debug"
APP_NAME="Diduny DEV"
BUNDLE_ID="ua.com.rmarinsky.diduny.dev"
BUILD_DIR="$SCRIPT_DIR/build"
APP_PATH="$BUILD_DIR/${CONFIG}/${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"

echo "=== Clean Install: $APP_NAME ==="
echo ""

# Step 1: Kill running process
echo "Killing $APP_NAME process if running..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

# Step 2: Remove from /Applications
if [ -d "$INSTALL_PATH" ]; then
    echo "Removing existing installation from /Applications..."
    rm -rf "$INSTALL_PATH"
fi

# Note: Permissions are preserved to avoid re-granting during development
# To reset permissions manually, run:
#   tccutil reset Accessibility "$BUNDLE_ID"
#   tccutil reset ScreenCapture "$BUNDLE_ID"
#   tccutil reset Microphone "$BUNDLE_ID"

echo "Clean-up complete."
echo ""

echo "=== Building $APP_NAME ==="
echo ""

# Check if xcodegen is installed and project needs regenerating
if [ ! -f "${PROJECT_NAME}.xcodeproj/project.pbxproj" ]; then
    echo "Xcode project not found. Generating..."
    if ! command -v xcodegen &> /dev/null; then
        echo "XcodeGen not found. Installing via Homebrew..."
        brew install xcodegen
    fi
    xcodegen generate
    echo ""
fi

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$BUILD_DIR"

# Build the app
echo "Building $APP_NAME ($CONFIG)..."
xcodebuild \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/${CONFIG}" \
    clean build \
    | grep -E "^(Build|Compiling|Linking|error:|warning:|\*\*)" || true

# Check if build succeeded
if [ ! -d "$APP_PATH" ]; then
    echo ""
    echo "Build failed. App not found at: $APP_PATH"
    exit 1
fi

echo ""
echo "Build successful: $APP_PATH"

# Copy to /Applications
echo "Installing to $INSTALL_PATH..."
cp -R "$APP_PATH" "$INSTALL_PATH"

# Clear quarantine attribute (keep Xcode's developer signature intact for TCC permissions)
xattr -cr "$INSTALL_PATH"

echo ""
echo "=== Installation Complete ==="
echo "App installed to: $INSTALL_PATH"
echo ""
echo "To launch: open -a '$APP_NAME'"
