#!/usr/bin/env bash
# Install the xCreen Mac app. By default this is a complete install: the app plus
# xcreen-server on this Mac (127.0.0.1). With --client it installs only the capture app
# and points it at a server elsewhere (for example Hermes on a home server over Tailscale).
#
#   bash scripts/install.sh [--vault /abs/path] [--no-launch]
#   bash scripts/install.sh --client --server URL [--token-file PATH] [--no-launch]
set -euo pipefail

cd "$(dirname "$0")/.."
DOMAIN="dev.xcreen.app"
DEST="$HOME/Applications/xCreen.app"
VAULT=""
LAUNCH=1
CLIENT=0
SERVER_URL=""
TOKEN_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    --client) CLIENT=1; shift ;;
    --server) SERVER_URL="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$(uname)" == "Darwin" ]] || { echo "The xCreen app needs macOS 14+; on Linux run scripts/install-server.sh" >&2; exit 1; }
command -v swift >/dev/null || { echo "Swift toolchain missing: run xcode-select --install" >&2; exit 1; }
if [[ $CLIENT -eq 1 && -z "$SERVER_URL" ]]; then echo "--client needs --server URL" >&2; exit 2; fi

if [[ $CLIENT -eq 0 ]]; then
  SERVER_ARGS=(--bind 127.0.0.1 --import-mac-app)
  [[ -n "$VAULT" ]] && SERVER_ARGS+=(--vault "$VAULT")
  bash scripts/install-server.sh "${SERVER_ARGS[@]}"
  SERVER_URL="http://127.0.0.1:$("$HOME/.local/bin/xcreen-server" config | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')"
fi

# A stable signing identity keeps the Screen Recording grant (and Keychain access) across reinstalls.
if [[ -z "${XCREEN_SIGN_IDENTITY:-}" ]]; then
  XCREEN_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
  export XCREEN_SIGN_IDENTITY
fi
bash scripts/build-app.sh
"$HOME/.local/bin/xcreen" quit >/dev/null 2>&1 || pkill -x xCreen 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R dist/xCreen.app "$DEST"
defaults write "$DOMAIN" xcreen.server.url -string "$SERVER_URL"

mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/xcreen"
install -m 755 bin/xcreen "$HOME/.local/bin/xcreen"

echo "Installed  $DEST"
echo "CLI        ~/.local/bin/xcreen  (xcreen status, xcreen server, xcreen logs)"
echo "Server     $SERVER_URL"

if [[ $LAUNCH -eq 1 ]]; then
  open "$DEST"
  for _ in $(seq 1 50); do [[ -S "$HOME/.xcreen-control/control.sock" ]] && break; sleep 0.1; done
  if [[ $CLIENT -eq 0 ]]; then
    "$HOME/.local/bin/xcreen-server" token | "$HOME/.local/bin/xcreen" server set "$SERVER_URL" --token-stdin
  elif [[ -n "$TOKEN_FILE" ]]; then
    "$HOME/.local/bin/xcreen" server set "$SERVER_URL" --token-file "$TOKEN_FILE"
  else
    echo "Now give the app the server token, e.g.:"
    echo "  ssh SERVER '~/.local/bin/xcreen-server token' | xcreen server set $SERVER_URL --token-stdin"
  fi
else
  echo "Start the app, then store the server token with: xcreen server set $SERVER_URL --token-stdin"
fi
