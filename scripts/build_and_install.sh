#!/bin/bash

# Build Diduny DEV and install to /Applications
# This script builds the development version with "Diduny DEV" name

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

PROJECT_NAME="Diduny"
SCHEME="Diduny DEV"
CONFIG="Debug"
APP_NAME="Diduny DEV"
BUNDLE_ID="ua.com.rmarinsky.diduny.dev"
BUILD_DIR="$PROJECT_DIR/build/dev-install"
APP_PATH="$BUILD_DIR/${CONFIG}/${APP_NAME}.app"
INSTALL_PATH="/Applications/${APP_NAME}.app"
DESTINATION="platform=macOS,arch=$(uname -m)"

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
if [ ! -f "$PROJECT_DIR/${PROJECT_NAME}.xcodeproj/project.pbxproj" ]; then
    echo "Xcode project not found. Generating..."
    if ! command -v xcodegen &> /dev/null; then
        if command -v brew &> /dev/null; then
            echo "XcodeGen not found. Installing via Homebrew..."
            brew install xcodegen
        else
            echo "XcodeGen not found and Homebrew is not installed. Install xcodegen and re-run."
            exit 1
        fi
    fi

    if [ ! -f "$PROJECT_DIR/project.yml" ]; then
        echo "No project spec found at $PROJECT_DIR/project.yml"
        exit 1
    fi

    xcodegen generate --spec "$PROJECT_DIR/project.yml"
    echo ""
fi

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$BUILD_DIR"

# Ensure build dir exists (needed for tee log file)
mkdir -p "$BUILD_DIR"

# Build the app
echo "Building $APP_NAME ($CONFIG)..."
xcodebuild \
    -project "$PROJECT_DIR/${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$BUILD_DIR" \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR/${CONFIG}" \
    clean build \
    | tee "$BUILD_DIR/xcodebuild.log" \
    | grep -E "^(Build|Compiling|Linking|error:|warning:|\*\*)" || true

# Check if build succeeded
if [ ! -d "$APP_PATH" ]; then
    echo ""
    echo "Build failed. App not found at: $APP_PATH"
    echo "See log: $BUILD_DIR/xcodebuild.log"
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
