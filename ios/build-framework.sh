#!/bin/bash
# Build the Go backend as OpenMessageKit.xcframework for iOS/iPadOS.
#
# Produces two slices from the same ./mobile package:
#   - ios-arm64            (physical iPad/iPhone)
#   - ios-arm64-simulator  (Simulator on Apple Silicon)
#
# Go targets iOS via GOOS=ios with cgo enabled. cgo is required by
# -buildmode=c-archive even though the backend itself has no C dependencies
# (modernc.org/sqlite is pure Go), so each slice needs a clang wrapper pinning
# the right SDK and -target triple. The simulator slice in particular *must*
# carry an explicit `-target arm64-apple-iosX-simulator` in CGO_CFLAGS/LDFLAGS:
# without it Go emits a device-platform Mach-O that xcodebuild will reject as a
# duplicate architecture when packaging the xcframework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
XCFRAMEWORK="$BUILD_DIR/OpenMessageKit.xcframework"
MIN_IOS="17.0"

VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)}"
GO_LDFLAGS="-s -w -X main.version=${VERSION}"

rm -rf "$BUILD_DIR/device" "$BUILD_DIR/sim" "$BUILD_DIR/sim-x64" "$XCFRAMEWORK"
mkdir -p "$BUILD_DIR/device" "$BUILD_DIR/sim" "$BUILD_DIR/sim-x64"

echo "==> Version: $VERSION"

# ── clang wrappers ──
# Go invokes $CC without knowing about Apple SDKs; these supply the sysroot,
# arch and deployment target for each slice.
cat > "$BUILD_DIR/clangwrap-device.sh" <<EOF
#!/bin/sh
exec "\$(xcrun --sdk iphoneos --find clang)" \\
    -arch arm64 \\
    -isysroot "\$(xcrun --sdk iphoneos --show-sdk-path)" \\
    -mios-version-min=$MIN_IOS "\$@"
EOF

cat > "$BUILD_DIR/clangwrap-sim.sh" <<EOF
#!/bin/sh
exec "\$(xcrun --sdk iphonesimulator --find clang)" \\
    -arch arm64 \\
    -isysroot "\$(xcrun --sdk iphonesimulator --show-sdk-path)" \\
    -mios-simulator-version-min=$MIN_IOS "\$@"
EOF

cat > "$BUILD_DIR/clangwrap-sim-x64.sh" <<EOF
#!/bin/sh
exec "\$(xcrun --sdk iphonesimulator --find clang)" \\
    -arch x86_64 \\
    -isysroot "\$(xcrun --sdk iphonesimulator --show-sdk-path)" \\
    -mios-simulator-version-min=$MIN_IOS "\$@"
EOF

chmod +x "$BUILD_DIR/clangwrap-device.sh" "$BUILD_DIR/clangwrap-sim.sh" "$BUILD_DIR/clangwrap-sim-x64.sh"

cd "$ROOT_DIR"

echo "==> Building device slice (ios/arm64)..."
GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
    CC="$BUILD_DIR/clangwrap-device.sh" \
    CXX="$BUILD_DIR/clangwrap-device.sh" \
    go build -trimpath -buildmode=c-archive -ldflags="$GO_LDFLAGS" \
        -o "$BUILD_DIR/device/libopenmessage.a" ./mobile
echo "    $(du -h "$BUILD_DIR/device/libopenmessage.a" | cut -f1)"

echo "==> Building simulator slice (ios/arm64-simulator)..."
GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
    CC="$BUILD_DIR/clangwrap-sim.sh" \
    CXX="$BUILD_DIR/clangwrap-sim.sh" \
    CGO_CFLAGS="-target arm64-apple-ios$MIN_IOS-simulator" \
    CGO_LDFLAGS="-target arm64-apple-ios$MIN_IOS-simulator" \
    go build -trimpath -buildmode=c-archive -ldflags="$GO_LDFLAGS" \
        -o "$BUILD_DIR/sim/libopenmessage.a" ./mobile
echo "    $(du -h "$BUILD_DIR/sim/libopenmessage.a" | cut -f1)"

echo "==> Building simulator slice (ios/amd64-simulator)..."
# Intel Macs run the x86_64 simulator. Both simulator architectures go into one
# fat library so the xcframework works regardless of the host Mac — an
# arm64-only simulator slice fails to link on Intel, and fails confusingly, as
# ld reports missing symbols rather than a missing architecture.
GOOS=ios GOARCH=amd64 CGO_ENABLED=1 \
    CC="$BUILD_DIR/clangwrap-sim-x64.sh" \
    CXX="$BUILD_DIR/clangwrap-sim-x64.sh" \
    CGO_CFLAGS="-target x86_64-apple-ios$MIN_IOS-simulator" \
    CGO_LDFLAGS="-target x86_64-apple-ios$MIN_IOS-simulator" \
    go build -trimpath -buildmode=c-archive -ldflags="$GO_LDFLAGS" \
        -o "$BUILD_DIR/sim-x64/libopenmessage.a" ./mobile
echo "    $(du -h "$BUILD_DIR/sim-x64/libopenmessage.a" | cut -f1)"

echo "==> Merging simulator architectures..."
lipo -create \
    "$BUILD_DIR/sim/libopenmessage.a" \
    "$BUILD_DIR/sim-x64/libopenmessage.a" \
    -output "$BUILD_DIR/sim/libopenmessage-fat.a"
mv "$BUILD_DIR/sim/libopenmessage-fat.a" "$BUILD_DIR/sim/libopenmessage.a"

# ── headers ──
# `go build -buildmode=c-archive` writes libopenmessage.h next to the archive.
# xcodebuild wants a headers *directory* per slice, with a module map so Swift
# can `import OpenMessageKit` rather than needing a bridging header (which an
# xcframework cannot supply).
for slice in device sim; do
    mkdir -p "$BUILD_DIR/$slice/include"
    mv "$BUILD_DIR/$slice/libopenmessage.h" "$BUILD_DIR/$slice/include/openmessage.h"
    cat > "$BUILD_DIR/$slice/include/module.modulemap" <<EOF
module OpenMessageKit {
    header "openmessage.h"
    export *
}
EOF
done

echo "==> Packaging XCFramework..."
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/device/libopenmessage.a" -headers "$BUILD_DIR/device/include" \
    -library "$BUILD_DIR/sim/libopenmessage.a"    -headers "$BUILD_DIR/sim/include" \
    -output "$XCFRAMEWORK" > /dev/null

echo ""
echo "==> Done: $XCFRAMEWORK"
echo "    Size: $(du -sh "$XCFRAMEWORK" | cut -f1)"
