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
# Since 2.0 the Hermes runtime ships with xcreen-server, not inside the app.
rm -rf "$APP/Contents/Resources/runtime"
cp "$BIN/xCreen" "$APP/Contents/MacOS/xCreen"
cp resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE NOTICE "$APP/Contents/Resources/"

# SwiftPM does not run Xcode's App Intents metadata extractor for a manually
# assembled app bundle. When the installed Xcode provides it, generate the
# metadata needed for macOS 26+ Spotlight action discovery.
rm -rf "$APP/Contents/Resources/Metadata.appintents"
METADATA_TOOL=""
if METADATA_TOOL="$(xcrun --find appintentsmetadataprocessor 2>/dev/null)"; then
  META_TMP="$(mktemp -d)"
  trap 'rm -rf "$META_TMP"' EXIT
  find "$PWD/Sources/XCreenApp" -name '*.swift' -print > "$META_TMP/sources"
  # Const values for the XCreenApp module only: swiftbuild backend (Release/xCreen-p.build) or
  # native SwiftPM (release/XCreenApp.build). They must include the AppShortcutsProvider.
  find "$PWD/.build" \( -path '*Release*xCreen-p.build*' -o -path '*release*XCreenApp.build*' \) \
    -name '*.swiftconstvalues' -print > "$META_TMP/constvalues"
  XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode /{print $2}')"
  if [[ ! -s "$META_TMP/constvalues" ]]; then
    # Hard failure locally; CI=true with Xcode < 27 (hosted runners) skips with a warning.
    python3 scripts/check-appintents-metadata.py --allow-missing-constvalues "$XCODE_VERSION" || exit 1
    SKIP_METADATA=1
  fi
fi
if [[ -n "${METADATA_TOOL:-}" && -z "${SKIP_METADATA:-}" ]]; then
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
  # Spotlight lists an app's actions from its App Shortcuts; fail if the action or shortcuts are missing.
  python3 scripts/check-appintents-metadata.py "$APP/Contents/Resources/Metadata.appintents"
elif [[ -z "${METADATA_TOOL:-}" ]]; then
  printf 'warning: appintentsmetadataprocessor not found (Xcode required); the Ask xCreen Spotlight action will not appear.\n' >&2
fi
# Ad-hoc signatures change every build, so macOS forgets the Screen Recording grant.
# Set XCREEN_SIGN_IDENTITY (e.g. an "Apple Development" identity) to keep it.
codesign --force --sign "${XCREEN_SIGN_IDENTITY:--}" "$APP"
printf 'Built %s/dist/xCreen.app (signed: %s, not notarized)\n' "$PWD" "${XCREEN_SIGN_IDENTITY:-ad-hoc}"
