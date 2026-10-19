#!/usr/bin/env bash
#
# build_libtorrent_ios.sh
# Compiles libtorrent 2.0.x for iOS Device (arm64) and Simulator (arm64, x86_64),
# builds the minimal Objective-C++ bridge (TorrentSessionBridge),
# and packages them into a universal LibTorrent.xcframework.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build-libtorrent-native"
FRAMEWORK_DIR="$REPO_ROOT/Frameworks"
SRC_DIR="$BUILD_DIR/libtorrent-src"

IPHONEOS_DEPLOYMENT_TARGET="15.0"
LIBTORRENT_TAG="v2.0.10"

echo "=========================================================="
echo " Starting libtorrent 2.0.x iOS Build (Milestone 1)"
echo " Target iOS Version: $IPHONEOS_DEPLOYMENT_TARGET"
echo " libtorrent Release: $LIBTORRENT_TAG"
echo "=========================================================="

mkdir -p "$BUILD_DIR"

# 1. Locate Boost headers
BOOST_PREFIX=$(brew --prefix boost 2>/dev/null || true)
if [ -z "$BOOST_PREFIX" ] || [ ! -d "$BOOST_PREFIX/include/boost" ]; then
    echo "==> Boost not found in default brew path. Attempting Homebrew installation..."
    brew install boost
    BOOST_PREFIX=$(brew --prefix boost)
fi
BOOST_INCLUDE="$BOOST_PREFIX/include"
echo "==> Found Boost headers at: $BOOST_INCLUDE"

# 2. Fetch libtorrent source
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Cloning libtorrent ($LIBTORRENT_TAG)..."
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$LIBTORRENT_TAG" https://github.com/arvidn/libtorrent.git "$SRC_DIR"
else
    echo "==> Using existing libtorrent source in $SRC_DIR"
fi

# 3. Generate Xcode multi-target project via CMake
CMAKE_BUILD="$BUILD_DIR/cmake-xcode"
mkdir -p "$CMAKE_BUILD"

echo "==> Generating multi-architecture Xcode project..."
cmake -B "$CMAKE_BUILD" \
    -S "$SRC_DIR" \
    -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD=gnu++17 \
    -DCMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
    -DBoost_INCLUDE_DIR="$BOOST_INCLUDE" \
    -DCMAKE_INCLUDE_PATH="$BOOST_INCLUDE" \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
    -Dbuild_tests=OFF \
    -Dbuild_examples=OFF \
    -Dbuild_tools=OFF \
    -Dpython-bindings=OFF \
    -Ddht=ON \
    -Dencryption=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=TRUE

# 4. Build libtorrent-rasterbar for iOS Device (arm64)
echo "==> Building libtorrent-rasterbar for iOS Device (iphoneos arm64)..."
xcodebuild \
    -project "$CMAKE_BUILD/libtorrent.xcodeproj" \
    -target torrent-rasterbar \
    -configuration Release \
    -sdk iphoneos \
    ARCHS="arm64" \
    IPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    SYMROOT="$BUILD_DIR/symroot" \
    build

# 5. Build libtorrent-rasterbar for iOS Simulator (arm64 + x86_64)
echo "==> Building libtorrent-rasterbar for iOS Simulator (iphonesimulator arm64, x86_64)..."
xcodebuild \
    -project "$CMAKE_BUILD/libtorrent.xcodeproj" \
    -target torrent-rasterbar \
    -configuration Release \
    -sdk iphonesimulator \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    IPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    SYMROOT="$BUILD_DIR/symroot" \
    build

DEVICE_LIB=$(find "$BUILD_DIR/symroot" -path "*Release-iphoneos*/libtorrent-rasterbar.a" | head -n 1)
SIM_LIB=$(find "$BUILD_DIR/symroot" -path "*Release-iphonesimulator*/libtorrent-rasterbar.a" | head -n 1)

if [ -z "$DEVICE_LIB" ] || [ ! -f "$DEVICE_LIB" ]; then
    echo "Error: Device libtorrent-rasterbar.a build failed!"
    exit 1
fi

if [ -z "$SIM_LIB" ] || [ ! -f "$SIM_LIB" ]; then
    echo "Error: Simulator libtorrent-rasterbar.a build failed!"
    exit 1
fi

echo "==> Found Device lib: $DEVICE_LIB"
echo "==> Found Simulator lib: $SIM_LIB"

# 6. Compile Objective-C++ Bridge (TorrentSessionBridge) for Device
echo "==> Compiling TorrentSessionBridge for iOS Device..."
IPHONEOS_SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang++ -c \
    -target arm64-apple-ios"$IPHONEOS_DEPLOYMENT_TARGET" \
    -isysroot "$IPHONEOS_SYSROOT" \
    -std=gnu++17 \
    -fobjc-arc \
    -I"$REPO_ROOT/Native/TorrentBridge/include" \
    -I"$SRC_DIR/include" \
    -I"$BOOST_INCLUDE" \
    "$REPO_ROOT/Native/TorrentBridge/src/TorrentSessionBridge.mm" \
    -o "$BUILD_DIR/TorrentSessionBridge-device.o"

libtool -static -o "$BUILD_DIR/libLibTorrent-device.a" \
    "$BUILD_DIR/TorrentSessionBridge-device.o" \
    "$DEVICE_LIB"

# 7. Compile Objective-C++ Bridge for Simulator (both arm64 and x86_64)
echo "==> Compiling TorrentSessionBridge for iOS Simulator..."
IPHONESIM_SYSROOT=$(xcrun --sdk iphonesimulator --show-sdk-path)

xcrun --sdk iphonesimulator clang++ -c \
    -target arm64-apple-ios"$IPHONEOS_DEPLOYMENT_TARGET"-simulator \
    -isysroot "$IPHONESIM_SYSROOT" \
    -std=gnu++17 \
    -fobjc-arc \
    -I"$REPO_ROOT/Native/TorrentBridge/include" \
    -I"$SRC_DIR/include" \
    -I"$BOOST_INCLUDE" \
    "$REPO_ROOT/Native/TorrentBridge/src/TorrentSessionBridge.mm" \
    -o "$BUILD_DIR/TorrentSessionBridge-sim-arm64.o"

xcrun --sdk iphonesimulator clang++ -c \
    -target x86_64-apple-ios"$IPHONEOS_DEPLOYMENT_TARGET"-simulator \
    -isysroot "$IPHONESIM_SYSROOT" \
    -std=gnu++17 \
    -fobjc-arc \
    -I"$REPO_ROOT/Native/TorrentBridge/include" \
    -I"$SRC_DIR/include" \
    -I"$BOOST_INCLUDE" \
    "$REPO_ROOT/Native/TorrentBridge/src/TorrentSessionBridge.mm" \
    -o "$BUILD_DIR/TorrentSessionBridge-sim-x86_64.o"

# Extract single-arch simulator slices to avoid duplicate architecture warnings
lipo "$SIM_LIB" -extract arm64 -output "$BUILD_DIR/libtorrent-sim-arm64.a"
lipo "$SIM_LIB" -extract x86_64 -output "$BUILD_DIR/libtorrent-sim-x86_64.a"

libtool -static -o "$BUILD_DIR/libLibTorrent-sim-arm64.a" \
    "$BUILD_DIR/TorrentSessionBridge-sim-arm64.o" \
    "$BUILD_DIR/libtorrent-sim-arm64.a"

libtool -static -o "$BUILD_DIR/libLibTorrent-sim-x86_64.a" \
    "$BUILD_DIR/TorrentSessionBridge-sim-x86_64.o" \
    "$BUILD_DIR/libtorrent-sim-x86_64.a"

lipo -create \
    "$BUILD_DIR/libLibTorrent-sim-arm64.a" \
    "$BUILD_DIR/libLibTorrent-sim-x86_64.a" \
    -output "$BUILD_DIR/libLibTorrent-sim.a"

# 8. Assemble unified XCFramework
echo "==> Packaging LibTorrent.xcframework..."
HEADERS_DIR="$BUILD_DIR/Headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$REPO_ROOT/Native/TorrentBridge/include/LibTorrent.h" "$HEADERS_DIR/"
cp "$REPO_ROOT/Native/TorrentBridge/include/TorrentSessionBridge.h" "$HEADERS_DIR/"
cp "$REPO_ROOT/Native/TorrentBridge/include/module.modulemap" "$HEADERS_DIR/"

rm -rf "$FRAMEWORK_DIR/LibTorrent.xcframework"
mkdir -p "$FRAMEWORK_DIR"

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/libLibTorrent-device.a" -headers "$HEADERS_DIR" \
    -library "$BUILD_DIR/libLibTorrent-sim.a" -headers "$HEADERS_DIR" \
    -output "$FRAMEWORK_DIR/LibTorrent.xcframework"

echo "=========================================================="
echo " LibTorrent.xcframework created successfully at:"
echo " $FRAMEWORK_DIR/LibTorrent.xcframework"
echo "=========================================================="

echo "Architecture verification:"
lipo -info "$FRAMEWORK_DIR/LibTorrent.xcframework/ios-arm64"/*.a
lipo -info "$FRAMEWORK_DIR/LibTorrent.xcframework/ios-arm64_x86_64-simulator"/*.a
