#!/usr/bin/env bash
# Install xcreen-server next to Hermes Agent (Linux or macOS) and run it as a user service.
#
#   bash scripts/install-server.sh [--bind ADDR | --tailscale] [--port N] [--vault PATH]
#                                  [--prefix DIR] [--import-mac-app] [--no-start]
#
# --bind defaults to 127.0.0.1 (same-machine client). --tailscale binds the machine's
# Tailscale IPv4 address so a Mac on the same tailnet can reach it.
set -euo pipefail

cd "$(dirname "$0")/.."
BIND=""
PORT=""
VAULT=""
VAULT_SET=0
PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/xcreen/app"
IMPORT=0
START=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bind) BIND="$2"; shift 2 ;;
    --tailscale) BIND="tailscale"; shift ;;
    --port) PORT="$2"; shift 2 ;;
    --vault) VAULT="$2"; VAULT_SET=1; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --import-mac-app) IMPORT=1; shift ;;
    --no-start) START=0; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ "$BIND" == "tailscale" ]]; then
  TS="$(command -v tailscale || true)"
  [[ -z "$TS" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]] && TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [[ -n "$TS" ]] || { echo "tailscale not found" >&2; exit 1; }
  BIND="$("$TS" ip -4 | head -1)"
  [[ -n "$BIND" ]] || { echo "this machine has no Tailscale IPv4 address (tailscale up?)" >&2; exit 1; }
fi

# Hermes reports its own Python and source root; the server runs on that same interpreter.
HERMES=""
for candidate in "$HOME/.local/bin/hermes" /opt/homebrew/bin/hermes /usr/local/bin/hermes /usr/bin/hermes "$(command -v hermes || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] && { HERMES="$candidate"; break; }
done
[[ -n "$HERMES" ]] || { echo "Hermes not found. Install Hermes Agent first." >&2; exit 1; }
read -r PYTHON ROOT < <(/usr/bin/env python3 -c '
import json, re, sys
argv = json.loads(sys.argv[1])
print(argv[0], re.search(r"sys\.path\.insert\(0, \x27([^\x27]+)\x27\)", argv[-1]).group(1))' "$("$HERMES" --print-runtime-command)")
[[ -x "$PYTHON" && -f "$ROOT/tui_gateway/entry.py" ]] || { echo "Hermes runtime not usable: $PYTHON / $ROOT" >&2; exit 1; }
"$PYTHON" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || { echo "Hermes Python must be 3.10+" >&2; exit 1; }

# Code: server package + scoped Hermes runtime, copied (not linked) so a checkout can move.
mkdir -p "$PREFIX/server" "$PREFIX/runtime"
rm -rf "$PREFIX/server/xcreen_server" "$PREFIX/runtime"/*.py
cp -R server/xcreen_server "$PREFIX/server/"
cp runtime/__init__.py runtime/xcreen_tools.py runtime/xcreen_gateway.py runtime/xcreen_receipts.py runtime/xcreen_rpc.py runtime/migrate_receipts.py "$PREFIX/runtime/"
find "$PREFIX" -name '__pycache__' -prune -exec rm -rf {} +

mkdir -p "$HOME/.local/bin"
LAUNCHER="$HOME/.local/bin/xcreen-server"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
exec "$PYTHON" -B -c 'import sys; sys.path.insert(0, "$PREFIX/server"); from xcreen_server.__main__ import main; sys.exit(main())' "\$@"
EOF
chmod 755 "$LAUNCHER"

INIT=(init --runtime-dir "$PREFIX/runtime")
[[ -n "$BIND" ]] && INIT+=(--bind "$BIND")
[[ -n "$PORT" ]] && INIT+=(--port "$PORT")
[[ $VAULT_SET -eq 1 ]] && INIT+=(--vault "$VAULT")
[[ $IMPORT -eq 1 ]] && INIT+=(--import-mac-app)
"$LAUNCHER" "${INIT[@]}" >/dev/null
"$LAUNCHER" config hermes_python="$PYTHON" hermes_root="$ROOT" >/dev/null

if [[ "$(uname)" == "Darwin" ]]; then
  mkdir -p "$HOME/Library/Logs/xCreen"
  "$LAUNCHER" config log_dir="$HOME/Library/Logs/xCreen" >/dev/null
  # Digested screenshots are recompressed with mozjpeg; without it they stay PNG.
  if [[ ! -x /opt/homebrew/opt/mozjpeg/bin/cjpeg && ! -x /usr/local/opt/mozjpeg/bin/cjpeg ]] && command -v brew >/dev/null; then
    brew install mozjpeg || echo "mozjpeg install failed: digested screenshots will stay PNG" >&2
  fi
fi

if [[ "$(uname)" != "Darwin" ]] && ! "$LAUNCHER" doctor 2>/dev/null | grep -q "compression: [mp]\|compression: libjpeg"; then
  echo "note: no JPEG encoder found; digested screenshots stay PNG. On Debian/Ubuntu: sudo apt install netpbm libjpeg-turbo-progs" >&2
fi

if [[ $START -eq 1 ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    PLIST="$HOME/Library/LaunchAgents/dev.xcreen.server.plist"
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.xcreen.server</string>
  <key>ProgramArguments</key><array><string>$LAUNCHER</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/xCreen/server.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/xCreen/server.log</string>
</dict></plist>
EOF
    launchctl bootout "gui/$(id -u)/dev.xcreen.server" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  else
    UNIT="$HOME/.config/systemd/user/xcreen-server.service"
    mkdir -p "$(dirname "$UNIT")"
    cat > "$UNIT" <<EOF
[Unit]
Description=xCreen server (screen memory for Hermes Agent)
Documentation=https://github.com/Al-ex-W/xCreen/blob/main/docs/client-server.md
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
ExecStart=$LAUNCHER serve
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
Environment=TZ=$("$LAUNCHER" config | "$PYTHON" -c 'import json,sys; print(json.load(sys.stdin)["timezone"])')

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now xcreen-server.service
    systemctl --user restart xcreen-server.service
    if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes; then
      echo "note: run 'sudo loginctl enable-linger $USER' so the server starts at boot without a login session" >&2
    fi
  fi
fi

"$LAUNCHER" doctor || true
CONFIG_BIND="$("$LAUNCHER" config | "$PYTHON" -c 'import json,sys; c=json.load(sys.stdin); print("%s:%s" % (c["bind"], c["port"]))')"
echo
echo "xcreen-server installed: $LAUNCHER (code in $PREFIX)"
echo "Listening on http://$CONFIG_BIND"
echo "Connect a Mac client with:"
echo "  ssh $(hostname) '$LAUNCHER token' | xcreen server set http://$CONFIG_BIND --token-stdin"
