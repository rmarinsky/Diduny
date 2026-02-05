#!/bin/bash

# Diduny Release Script
# Builds, signs, notarizes, and packages the app for distribution
#
# Usage:
#   ./release.sh                    # Build PROD (Diduny) - Interactive notarization
#   ./release.sh --test             # Build TEST (Diduny TEST) - Interactive notarization
#   ./release.sh --skip-notarize    # Build PROD without notarization
#   ./release.sh --test --skip-notarize  # Build TEST without notarization
#
# Build Types:
#   PROD (default): App name "Diduny", bundle ID "ua.com.rmarinsky.diduny"
#   TEST (--test):  App name "Diduny TEST", bundle ID "ua.com.rmarinsky.diduny.test"
#
# Prerequisites:
#   1. Apple Developer Program membership
#   2. Developer ID Application certificate installed in Keychain
#   3. For notarization: App-specific password from appleid.apple.com
#
# Environment variables (optional, will prompt if not set):
#   APPLE_ID          - Your Apple ID email
#   APP_PASSWORD      - App-specific password for notarization
#   TEAM_ID           - Your Apple Developer Team ID (default: 8JL9TM5WLG)

set -e

# Default configuration (PROD)
BUILD_TYPE="prod"
SCHEME="Diduny"
CONFIG="Release"
APP_NAME="Diduny"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
TEAM_ID="${TEAM_ID:-8JL9TM5WLG}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
SKIP_NOTARIZE=false
for arg in "$@"; do
    case $arg in
        --skip-notarize)
            SKIP_NOTARIZE=true
            ;;
        --test)
            BUILD_TYPE="test"
            SCHEME="Diduny TEST"
            CONFIG="Test"
            APP_NAME="Diduny TEST"
            ;;
    esac
done

# Set paths based on configuration
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                 Diduny Release Builder                    ║"
echo "║                   ua.com.rmarinsky                        ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
BUILD_TYPE_UPPER=$(echo "$BUILD_TYPE" | tr '[:lower:]' '[:upper:]')
echo -e "  ${BLUE}Build Type:${NC}    ${BUILD_TYPE_UPPER}"
echo -e "  ${BLUE}Scheme:${NC}        ${SCHEME}"
echo -e "  ${BLUE}Configuration:${NC} ${CONFIG}"
echo -e "  ${BLUE}App Name:${NC}      ${APP_NAME}"
echo ""

# Step 1: Clean previous build
echo -e "${YELLOW}[1/6] Cleaning previous build...${NC}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Step 2: Generate Xcode project (in case project.yml changed)
echo -e "${YELLOW}[2/6] Generating Xcode project...${NC}"
if command -v xcodegen &> /dev/null; then
    xcodegen generate --quiet
else
    echo -e "${RED}Error: XcodeGen not installed. Run: brew install xcodegen${NC}"
    exit 1
fi

# Step 3: Build archive
echo -e "${YELLOW}[3/6] Building release archive...${NC}"
xcodebuild -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -archivePath "${ARCHIVE_PATH}" \
    archive \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_IDENTITY="Apple Development" \
    2>&1 | grep -E "(error:|warning:|BUILD|Signing)" || true

if [ ! -d "${ARCHIVE_PATH}" ]; then
    echo -e "${RED}Error: Archive failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Archive created${NC}"

# Step 4: Export for distribution
echo -e "${YELLOW}[4/6] Exporting for Developer ID distribution...${NC}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${PROJECT_DIR}/ExportOptions.plist" \
    2>&1 | grep -E "(error:|warning:|EXPORT)" || true

if [ ! -d "${APP_PATH}" ]; then
    echo -e "${RED}Error: Export failed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ App exported${NC}"

# Step 5: Notarize (optional)
if [ "$SKIP_NOTARIZE" = false ]; then
    echo -e "${YELLOW}[5/6] Notarizing with Apple...${NC}"

    # Check for credentials
    if [ -z "$APPLE_ID" ]; then
        echo -n "Enter your Apple ID (email): "
        read APPLE_ID
    fi

    if [ -z "$APP_PASSWORD" ]; then
        echo -e "${BLUE}Note: Use an app-specific password from https://appleid.apple.com${NC}"
        echo -n "Enter app-specific password: "
        read -s APP_PASSWORD
        echo ""
    fi

    # Create ZIP for notarization
    echo "Creating ZIP for notarization..."
    ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
    ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

    # Submit for notarization
    echo "Submitting to Apple notarization service..."
    xcrun notarytool submit "${ZIP_PATH}" \
        --apple-id "${APPLE_ID}" \
        --password "${APP_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    # Staple the notarization ticket
    echo "Stapling notarization ticket..."
    xcrun stapler staple "${APP_PATH}"

    # Clean up ZIP
    rm -f "${ZIP_PATH}"

    echo -e "${GREEN}✓ Notarization complete${NC}"
else
    echo -e "${YELLOW}[5/6] Skipping notarization (--skip-notarize)${NC}"
fi

# Step 6: Create DMG
echo -e "${YELLOW}[6/6] Creating DMG installer...${NC}"

# Create a temporary folder for DMG contents
DMG_TEMP="${BUILD_DIR}/dmg_temp"
mkdir -p "${DMG_TEMP}"
cp -R "${APP_PATH}" "${DMG_TEMP}/"

# Create symbolic link to Applications
ln -s /Applications "${DMG_TEMP}/Applications"

# Create DMG
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_PATH}"

# Clean up
rm -rf "${DMG_TEMP}"

echo -e "${GREEN}✓ DMG created${NC}"

# Get version info
VERSION=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)
BUILD=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion)

echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    BUILD COMPLETE                         ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "  ${BLUE}Build Type:${NC} ${BUILD_TYPE_UPPER}"
echo -e "  ${BLUE}App:${NC}        ${APP_PATH}"
echo -e "  ${BLUE}DMG:${NC}        ${DMG_PATH}"
echo -e "  ${BLUE}Version:${NC}    ${VERSION} (${BUILD})"
echo ""

if [ "$SKIP_NOTARIZE" = false ]; then
    echo -e "  ${GREEN}✓ Signed with Developer ID${NC}"
    echo -e "  ${GREEN}✓ Notarized by Apple${NC}"
    echo -e "  ${GREEN}✓ Ready for distribution${NC}"
else
    echo -e "  ${YELLOW}⚠ Not notarized - users may see Gatekeeper warnings${NC}"
    echo -e "  ${YELLOW}  Run without --skip-notarize for full distribution${NC}"
fi

echo ""
echo -e "To open the DMG:"
echo -e "  ${BLUE}open ${DMG_PATH}${NC}"
echo ""
