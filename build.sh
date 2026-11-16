#!/bin/bash
set -e

echo "=== Building Darwin25Probe for iOS ==="
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
echo "Using SDK: $SDK_PATH"

rm -rf build
mkdir -p build/Payload/Darwin25Probe.app

echo "Compiling main.m for arm64 / arm64e..."
clang -arch arm64 -arch arm64e \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min=15.0 \
    -framework UIKit \
    -framework Foundation \
    -framework IOKit \
    -fobjc-arc \
    -O2 \
    main.m \
    -o build/Payload/Darwin25Probe.app/Darwin25Probe

echo "Copying bundle resources..."
cp Info.plist build/Payload/Darwin25Probe.app/Info.plist

echo "Performing ad-hoc signature..."
codesign -s - --entitlements entitlements.plist --force --deep build/Payload/Darwin25Probe.app

echo "Packaging IPA..."
cd build
zip -r ../Darwin25Probe.ipa Payload
cd ..

ls -lh Darwin25Probe.ipa
echo "=== Done: Darwin25Probe.ipa created ==="
