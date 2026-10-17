#!/bin/bash
# Dev-only: renders docs/assets/tray.png (real tray Panel view, synthetic demo state, 2x)
# and docs/assets/social-preview.png (1280x640). Never captures the screen or reads user data.
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_ARGS=()
if [[ "${XCREEN_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
  SWIFT_ARGS+=(--disable-sandbox)
fi
swift build ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} --product XCreenScreenshots
BIN="$(swift build ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} --show-bin-path)"
"$BIN/XCreenScreenshots" docs/assets/tray.png
"$BIN/XCreenScreenshots" --social docs/assets/tray.png docs/assets/social-preview.png
