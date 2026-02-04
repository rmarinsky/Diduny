#!/bin/bash

# Generate Xcode project for Diduny

set -e

echo "=== Diduny Project Generator ==="
echo ""

# Check if xcodegen is installed
if ! command -v xcodegen &> /dev/null; then
    echo "XcodeGen not found. Installing via Homebrew..."
    brew install xcodegen
fi

# Generate project
echo "Generating Xcode project..."
xcodegen generate

echo ""
echo "✅ Project generated successfully!"
echo ""
echo "Next steps:"
echo "1. Open Diduny.xcodeproj in Xcode"
echo "2. Set your Development Team in Signing & Capabilities"
echo "3. Build and run (⌘R)"
echo ""
echo "To open the project:"
echo "  open Diduny.xcodeproj"
