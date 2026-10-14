#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_ARGS=()
if [[ "${XCREEN_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--disable-sandbox)
fi
swift build ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} -c release -debug-info-format none
BIN="$(swift build ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} -c release -debug-info-format none --show-bin-path)"
APP="dist/xCreen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -rf "$APP/Contents/Resources/bridge"
rm -rf "$APP/Contents/Resources/runtime"
cp "$BIN/xCreen" "$APP/Contents/MacOS/xCreen"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE NOTICE "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/runtime"
cp runtime/__init__.py runtime/xcreen_tools.py runtime/xcreen_gateway.py "$APP/Contents/Resources/runtime/"

# SwiftPM does not run Xcode's App Intents metadata extractor for a manually
# assembled app bundle. When the installed Xcode provides it, generate the
# metadata needed for macOS 26+ Spotlight action discovery.
rm -rf "$APP/Contents/Resources/Metadata.appintents"
if METADATA_TOOL="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)"; then
  META_TMP="$(mktemp -d)"
  trap 'rm -rf "$META_TMP"' EXIT
  find "$PWD/Sources/XCreenApp" -name '*.swift' -print > "$META_TMP/sources"
  find "$PWD/.build" -path '*Release*xCreen-p.build*' -name '*.swiftconstvalues' -print > "$META_TMP/constvalues"
  if [[ -s "$META_TMP/constvalues" ]]; then
    XCODE_BUILD="$(xcodebuild -version | awk '/Build version/{print $3}')"
    "$METADATA_TOOL" \
      --output "$APP/Contents/Resources" \
      --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
      --module-name XCreenApp \
      --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
      --xcode-version "$XCODE_BUILD" \
      --platform-family macOS \
      --deployment-target 14.0 \
      --target-triple "$(uname -m)-apple-macos14.0" \
      --source-file-list "$META_TMP/sources" \
      --swift-const-vals-list "$META_TMP/constvalues" \
      --deployment-aware-processing \
      --force
  fi
fi
codesign --force --sign - "$APP"
printf 'Built %s/dist/xCreen.app (ad-hoc signed, not notarized)\n' "$PWD"
