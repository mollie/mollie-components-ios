#!/usr/bin/env bash
set -euo pipefail

SCHEME="MollieComponents"
BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
OUTPUT="$BUILD_DIR/MollieComponents.xcframework"
TARGETS=(MollieCore MolliePayments MolliePaymentsUI MollieComponents)

rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

build_platform() {
    local destination="$1"
    xcodebuild build \
        -scheme "$SCHEME" \
        -destination "$destination" \
        -derivedDataPath "$DERIVED_DATA" \
        -configuration Release \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        CODE_SIGNING_ALLOWED=NO
}

build_platform "generic/platform=iOS"
build_platform "generic/platform=iOS Simulator"

make_lib() {
    local products="$1"
    local out="$2"
    local objects=()
    for t in "${TARGETS[@]}"; do
        objects+=("$products/$t.o")
    done
    libtool -static -o "$out/MollieComponents.a" "${objects[@]}"
    # Copy swiftmodule directories for all targets so xcframework consumers
    # can import each module individually (MollieCore, MolliePayments, etc.)
    for t in "${TARGETS[@]}"; do
        cp -r "$products/$t.swiftmodule" "$out/"
    done
}

mkdir -p "$BUILD_DIR/ios" "$BUILD_DIR/sim"
make_lib "$DERIVED_DATA/Build/Products/Release-iphoneos"        "$BUILD_DIR/ios"
make_lib "$DERIVED_DATA/Build/Products/Release-iphonesimulator" "$BUILD_DIR/sim"

xcodebuild -create-xcframework \
    -library "$BUILD_DIR/ios/MollieComponents.a" \
    -library "$BUILD_DIR/sim/MollieComponents.a" \
    -output "$OUTPUT"

# xcodebuild -create-xcframework only bundles the swiftmodule matching the
# library name. Copy the remaining per-module swiftmodules into each slice
# so consumers can import MollieCore, MolliePayments, etc. individually.
for slice in "$OUTPUT"/*/; do
    if [[ "$slice" == *simulator* ]]; then
        src="$BUILD_DIR/sim"
    else
        src="$BUILD_DIR/ios"
    fi
    for t in "${TARGETS[@]}"; do
        [[ "$t" == "MollieComponents" ]] && continue
        cp -r "$src/$t.swiftmodule" "$slice"
    done
done

echo "Built: $OUTPUT"
