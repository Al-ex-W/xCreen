#!/usr/bin/env bash
# Build xCreen, install it to ~/Applications and pre-fill local settings.
# Usage: bash scripts/install.sh [--vault /abs/path] [--no-launch]
set -euo pipefail

cd "$(dirname "$0")/.."
DOMAIN="dev.xcreen.app"
DEST="$HOME/Applications/xCreen.app"
VAULT=""
LAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || { echo "xCreen needs macOS 14+" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift toolchain missing: run xcode-select --install" >&2; exit 1; }

# Digested screenshots are recompressed with mozjpeg; without it they stay PNG (~8x larger).
if [[ ! -x /opt/homebrew/opt/mozjpeg/bin/cjpeg && ! -x /usr/local/opt/mozjpeg/bin/cjpeg ]]; then
  if command -v brew >/dev/null; then
    brew install mozjpeg || echo "mozjpeg install failed: digested screenshots will stay PNG" >&2
  else
    echo "Homebrew not found: digested screenshots will stay PNG (install mozjpeg to compress them)" >&2
  fi
fi

# Hermes reports its own Python and source root; this is the same lookup the app does.
HERMES=""
for candidate in "$HOME/.local/bin/hermes" /opt/homebrew/bin/hermes /usr/local/bin/hermes "$(command -v hermes || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] && { HERMES="$candidate"; break; }
done
[[ -n "$HERMES" ]] || { echo "Hermes not found. Install Hermes Agent first." >&2; exit 1; }

RUNTIME_JSON="$("$HERMES" --print-runtime-command)"
read -r PYTHON ROOT < <(/usr/bin/python3 -c '
import json, re, sys
argv = json.loads(sys.argv[1])
root = re.search(r"sys\.path\.insert\(0, \x27([^\x27]+)\x27\)", argv[-1]).group(1)
print(argv[0], root)' "$RUNTIME_JSON")
[[ -f "$ROOT/tui_gateway/entry.py" ]] || { echo "Hermes root has no tui_gateway: $ROOT" >&2; exit 1; }

if [[ -z "$VAULT" ]]; then
  VAULT="$(/usr/bin/python3 - <<'PY'
import json, os
path = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
env = os.environ.get("OBSIDIAN_VAULT_PATH", "")
if env and os.path.isdir(env):
    print(env); raise SystemExit
try:
    vaults = json.load(open(path)).get("vaults", {}).values()
except Exception:
    raise SystemExit
best = max(
    (v for v in vaults if os.path.isdir(v.get("path", ""))),
    key=lambda v: (os.path.isdir(os.path.join(v["path"], "Daily")), bool(v.get("open")), v.get("ts", 0)),
    default=None,
)
if best:
    print(best["path"])
PY
)"
fi

# A stable signing identity keeps the Screen Recording grant across reinstalls.
if [[ -z "${XCREEN_SIGN_IDENTITY:-}" ]]; then
  XCREEN_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
  export XCREEN_SIGN_IDENTITY
fi
bash scripts/build-app.sh
pkill -x xCreen 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R dist/xCreen.app "$DEST"

defaults write "$DOMAIN" xcreen.hermes.python -string "$PYTHON"
defaults write "$DOMAIN" xcreen.hermes.root -string "$ROOT"
[[ -n "$VAULT" ]] && defaults write "$DOMAIN" xcreen.vault.path -string "$VAULT"

mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/xcreen"
install -m 755 bin/xcreen "$HOME/.local/bin/xcreen"

echo "Installed  $DEST"
echo "CLI        ~/.local/bin/xcreen  (xcreen status, xcreen logs)"
echo "Python     $PYTHON"
echo "Hermes     $ROOT"
echo "Vault      ${VAULT:-<none: Daily-note writing disabled>}"
[[ $LAUNCH -eq 1 ]] && open "$DEST"
