#!/bin/bash
set -euo pipefail

# Build whisper.cpp as an XCFramework for macOS (arm64 + x86_64)
# Requires: cmake, Xcode command line tools
# Output: Frameworks/whisper.xcframework

WHISPER_TAG="v1.7.3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.whisper-build"
OUTPUT_DIR="$PROJECT_DIR/Frameworks"

echo "=== Building whisper.cpp XCFramework ==="
echo "Tag: $WHISPER_TAG"
echo "Build dir: $BUILD_DIR"
echo "Output dir: $OUTPUT_DIR"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Clone whisper.cpp
echo ""
echo "=== Cloning whisper.cpp ($WHISPER_TAG) ==="
git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggerganov/whisper.cpp.git "$BUILD_DIR/whisper.cpp"

WHISPER_SRC="$BUILD_DIR/whisper.cpp"

# Function to build for a specific architecture
build_arch() {
    local ARCH=$1
    local BUILD_PATH="$BUILD_DIR/build-$ARCH"

    echo ""
    echo "=== Building for $ARCH ==="
    mkdir -p "$BUILD_PATH"

    local EXTRA_FLAGS=""
    if [ "$ARCH" = "x86_64" ]; then
        # Disable native CPU detection for cross-compilation to x86_64
        # and disable Metal (not available on x86_64 Macs without Apple Silicon)
        EXTRA_FLAGS="-DGGML_NATIVE=OFF -DGGML_METAL=OFF -DWHISPER_METAL=OFF"
    else
        EXTRA_FLAGS="-DGGML_METAL=ON"
    fi

    cmake -S "$WHISPER_SRC" -B "$BUILD_PATH" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="14.0" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_COREML=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        $EXTRA_FLAGS

    cmake --build "$BUILD_PATH" --config Release -j "$(sysctl -n hw.ncpu)"

    echo "=== $ARCH build complete ==="
}

# Build both architectures
build_arch "arm64"
build_arch "x86_64"

# Merge all static libraries per architecture, then create universal fat binary
echo ""
echo "=== Merging static libraries ==="
UNIVERSAL_DIR="$BUILD_DIR/universal"
mkdir -p "$UNIVERSAL_DIR/lib" "$UNIVERSAL_DIR/include"

# For each architecture, merge all .a files into one combined libwhisper.a
for ARCH in arm64 x86_64; do
    BUILD_PATH="$BUILD_DIR/build-$ARCH"
    MERGED_DIR="$BUILD_DIR/merged-$ARCH"
    mkdir -p "$MERGED_DIR"

    # Find all static libraries (whisper + ggml*)
    ALL_LIBS=$(find "$BUILD_PATH" -name "*.a" -type f)
    echo "=== $ARCH libraries found ==="
    echo "$ALL_LIBS"

    # Merge all .a into single libwhisper.a using libtool
    libtool -static -o "$MERGED_DIR/libwhisper.a" $ALL_LIBS
    echo "Merged all $ARCH libs into single libwhisper.a"
done

# Create universal (fat) binary from merged libs
lipo -create \
    "$BUILD_DIR/merged-arm64/libwhisper.a" \
    "$BUILD_DIR/merged-x86_64/libwhisper.a" \
    -output "$UNIVERSAL_DIR/lib/libwhisper.a"
echo "Created universal libwhisper.a"

# Copy all required headers
# whisper.h includes ggml.h and ggml-cpu.h, which may include others
REQUIRED_HEADERS="whisper.h ggml.h ggml-cpu.h ggml-alloc.h ggml-backend.h ggml-opt.h"
for header in $REQUIRED_HEADERS; do
    FOUND=$(find "$WHISPER_SRC" -name "$header" -not -path "*/build*" -not -path "*/.git/*" | head -1)
    if [ -n "$FOUND" ]; then
        cp "$FOUND" "$UNIVERSAL_DIR/include/"
        echo "Copied header: $header"
    fi
done

# Also copy any other ggml headers that might be needed transitively
find "$WHISPER_SRC/ggml/include" -name "*.h" -exec cp {} "$UNIVERSAL_DIR/include/" \; 2>/dev/null || true
find "$WHISPER_SRC/include" -name "*.h" -exec cp {} "$UNIVERSAL_DIR/include/" \; 2>/dev/null || true

# Copy Metal shader if it exists
METAL_LIB=$(find "$BUILD_DIR/build-arm64" -name "*.metallib" -type f | head -1)
if [ -n "$METAL_LIB" ]; then
    cp "$METAL_LIB" "$UNIVERSAL_DIR/lib/"
    echo "Copied Metal library"
fi

# Also check for default.metallib or ggml.metallib
find "$BUILD_DIR/build-arm64" -name "*.metal" -type f -exec cp {} "$UNIVERSAL_DIR/lib/" \; 2>/dev/null || true

# Create xcframework
echo ""
echo "=== Creating XCFramework ==="
rm -rf "$OUTPUT_DIR/whisper.xcframework"
mkdir -p "$OUTPUT_DIR"

# Create a module map for the framework
# Remove C++ headers that break bridging header compilation
rm -f "$UNIVERSAL_DIR/include/ggml-cpp.h" 2>/dev/null

cat > "$UNIVERSAL_DIR/include/module.modulemap" << 'EOF'
module whisper {
    header "whisper.h"
    header "ggml.h"
    header "ggml-cpu.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    export *
}
EOF

xcodebuild -create-xcframework \
    -library "$UNIVERSAL_DIR/lib/libwhisper.a" \
    -headers "$UNIVERSAL_DIR/include" \
    -output "$OUTPUT_DIR/whisper.xcframework"

# Copy metal resources into the xcframework
XCFW_LIB_DIR=$(find "$OUTPUT_DIR/whisper.xcframework" -name "*.a" -type f -exec dirname {} \; | head -1)
if [ -n "$XCFW_LIB_DIR" ]; then
    for metal_file in "$UNIVERSAL_DIR"/lib/*.metallib "$UNIVERSAL_DIR"/lib/*.metal; do
        if [ -f "$metal_file" ]; then
            cp "$metal_file" "$XCFW_LIB_DIR/"
            echo "Copied $(basename "$metal_file") into xcframework"
        fi
    done
fi

echo ""
echo "=== XCFramework created at: $OUTPUT_DIR/whisper.xcframework ==="

# Clean up build directory
echo ""
echo "=== Cleaning up ==="
rm -rf "$BUILD_DIR"

echo "=== Done ==="
