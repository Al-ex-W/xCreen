# Installing xCreen

xCreen 2.0 is two programs: the **Mac app** (capture, OCR, tray, CLI) and **`xcreen-server`** (evidence, batching, the Hermes session, notes), which runs next to your [Hermes Agent](https://github.com/NousResearch/hermes-agent). Pick a layout:

| Layout | Hermes runs on | Install |
|---|---|---|
| Complete | the same Mac | `bash scripts/install.sh` |
| Split | another machine (Linux or macOS), reached over Tailscale or a private network | `scripts/install-server.sh` on the server, `scripts/install.sh --client` on the Mac |

Both run the same code; see [client and server](docs/client-server.md).

Requirements:

- **Mac app:** macOS 14+, Xcode/Swift to build.
- **Server:** an installed Hermes Agent (check with `hermes --print-runtime-command`); the server runs on Hermes's own Python, 3.10 or newer. To recompress digested screenshots it uses mozjpeg (Homebrew `mozjpeg`), Pillow, or on Debian/Ubuntu `sudo apt install netpbm libjpeg-turbo-progs`. Without any of them screenshots simply stay PNG.

xCreen uses your Hermes profile read-only and sends inference to whichever provider the xCreen session's route uses; local OCR does not make inference local. If you're an agent installing this: do not edit Hermes auth/config, grant screen permissions, turn Integrity OFF, inspect vault contents or run inference to verify the installation.

## Complete install (Hermes on this Mac)

```sh
git clone https://github.com/Al-ex-W/xCreen.git
cd xCreen
bash scripts/install.sh --no-launch
```

This installs `xcreen-server` (code in `~/.local/share/xcreen/app`, command in `~/.local/bin/xcreen-server`) as the LaunchAgent `dev.xcreen.server` on `127.0.0.1:8765`, finds Hermes and your Obsidian vault (`--vault "/absolute/path"` overrides), builds the app into `~/Applications` and copies the `xcreen` CLI to `~/.local/bin`. Add that directory to PATH.

Upgrading from 1.x keeps everything: the server opens the existing evidence store and imports the Hermes paths, vault, session, visibility and model default from the 1.x app's preferences.

Omit `--no-launch` and the installer also starts the app and stores the server token in your Keychain. Otherwise do that once the app runs:

```sh
xcreen-server token | xcreen server set http://127.0.0.1:8765 --token-stdin
```

## Split install (Hermes on a server)

On the server, as the user that runs Hermes:

```sh
git clone https://github.com/Al-ex-W/xCreen.git
cd xCreen
bash scripts/install-server.sh --tailscale --vault "/absolute/path/to/vault/on/the/server"
```

- `--tailscale` binds the server to the machine's Tailscale IPv4 address, so only devices on your tailnet can reach it and WireGuard encrypts the traffic. `--bind ADDR` picks another address; the server refuses `0.0.0.0`.
- On Linux it runs as the systemd user service `xcreen-server` (`systemctl --user status xcreen-server`). For it to start at boot without a login session: `sudo loginctl enable-linger $USER`. On macOS it's the LaunchAgent `dev.xcreen.server`.
- The server owns the vault: notes are written to the vault folder on the server. Keeping that folder in sync with the Obsidian vault on your other devices (Obsidian Sync, Syncthing, …) is up to you.
- The script ends with `xcreen-server doctor`, which checks config, token, Hermes, runtime, vault and the compression encoder.

On the Mac:

```sh
git clone https://github.com/Al-ex-W/xCreen.git
cd xCreen
bash scripts/install.sh --client --server http://SERVER-TAILSCALE-IP:8765
ssh SERVER '~/.local/bin/xcreen-server token' | xcreen server set http://SERVER-TAILSCALE-IP:8765 --token-stdin
xcreen server
```

`xcreen server` should report the server as reachable. The MagicDNS name (`http://hermes.your-tailnet.ts.net:8765`) works as well. Plain HTTP is accepted only for loopback, private networks, Tailscale and `*.ts.net`/`*.local` names; use HTTPS (for example `tailscale serve`) for anything else.

If the server is unreachable, the app keeps capturing into its local outbox (private, seven-day retention) and uploads it once the server is back. `xcreen flush` uploads immediately.

## Moving an existing install to a server

Your 1.x Mac or a complete install already has an evidence store, a receipts journal and a Hermes session. To carry them over:

1. Stop capture and the old server: `xcreen quit` (and on a complete install `launchctl bootout gui/$(id -u)/dev.xcreen.server`).
2. Install the server (above) with `--no-start`, then copy the evidence store and the receipts journal:

   ```sh
   rsync -a --exclude capture-checkpoint.json "$HOME/Library/Application Support/xCreen/Evidence/" SERVER:.local/share/xcreen/evidence/
   rsync -a ~/.hermes/xcreen-receipts/ SERVER:.hermes/xcreen-receipts/
   ```

3. On the Mac, print the xCreen session id and the vault path the 1.x app used:

   ```sh
   python3 -c 'import json,plistlib,subprocess; p=plistlib.loads(subprocess.run(["defaults","export","dev.xcreen.app","-"],capture_output=True).stdout); print(json.loads(p["xcreen.hermes.session.record"])["storedSessionID"]); print(p.get("xcreen.vault.path",""))'
   ```

   On the server, resume that Hermes session and carry the receipts journal over to the server's vault path (the journal is keyed by the vault's path, which differs between machines):

   ```sh
   xcreen-server init --session-id SESSION_ID
   xcreen-server migrate-journal --from-vault "MAC_VAULT_PATH"
   systemctl --user start xcreen-server
   ```

   Hermes resumes the session only if the server's Hermes has it (for example because you migrated `~/.hermes` too); otherwise skip `--session-id` and the server starts a new xCreen session.

4. Install the Mac client and give it the token (above). On connect the server verifies every batch receipt: batches whose notes were written stay completed, nothing is resent.

The store can be copied as is: image paths are re-anchored by file name, so a store written on the Mac opens on Linux.

## Install from the release

Download `xCreen-2.0.0-macos.zip` from [release 2.0.0](https://github.com/Al-ex-W/xCreen/releases/tag/v2.0.0), unzip it and move `xCreen.app` to `~/Applications`. The app isn't notarized, so on first open go to System Settings → Privacy & Security and click Open Anyway. The server installs from a checkout (`scripts/install-server.sh`).

## Verify without capture or inference

```sh
xcreen status
xcreen server
xcreen integrity get
xcreen session visibility get
xcreen settings show
xcreen models list
xcreen logs --no-follow
```

Status comes from the running app and the server, not a stale file. It must report Integrity true and capture paused. Connecting and listing models resume only the dedicated xCreen session and run no model. If the default model isn't in Hermes's inventory, status says so and automatic batches wait; nothing falls back to another model. Avoid publishing settings or log output: it can contain personal paths or identifiers.

On the server: `xcreen-server doctor`, and logs with `journalctl --user -u xcreen-server` (Linux) or `xcreen logs --server` (a server on the same Mac).

## Settings

```sh
xcreen settings set python /absolute/python3          # paths on the server
xcreen settings set root /absolute/hermes-agent
xcreen settings set vault "/absolute/vault"
xcreen settings set vault ""                          # disables note writing
xcreen settings set timezone Europe/Stockholm         # capture-date Daily notes use this zone
xcreen settings autodetect                            # finds Hermes and the vault on the server
xcreen connection reconnect
xcreen model default                                  # show the xCreen session default
xcreen model select PROVIDER EXACT_MODEL_ID           # also saves it as the xCreen default
```

Settings are stored by the server, which reconnects Hermes after a change; the session identity is kept. The xCreen session default is Claude Haiku 5.5 on your Anthropic account (`anthropic` / `claude-haiku-5-5`) until you pick another configured route in the tray or with `xcreen model default PROVIDER MODEL`. It applies only to the xCreen session, never Hermes's global default. An unavailable model is reported rather than replaced, and automatic batches wait until it's available; the server re-checks every five minutes.

Bind address, port, data directory and token are changed on the server only: `xcreen-server config KEY=VALUE`, `xcreen-server token --rotate` (then `xcreen server set … --token-stdin` again on the Mac).

## Updating

```sh
git pull && bash scripts/install-server.sh --tailscale   # on the server: copies the new code and restarts it
git pull && bash scripts/install.sh --client --server URL  # on the Mac
```

Client and server check each other's protocol version and refuse to talk across incompatible versions.

## User-only deliberate actions

The **Show session in Hermes** tray toggle defaults OFF (hidden). `xcreen session visibility on|off` changes the same persisted preference on the server. `xcreen --json status` separates the desired `sessionVisible`, the last Hermes-confirmed `actualSessionVisible` and `sessionVisibilityPending`.

- Integrity OFF in the tray or `xcreen integrity off` explicitly consents to capture. The same capture service runs the permission, lock-state and exclusion gates for both. Permission denial leaves your desired switch unchanged and reports capture blocked; an explicit OFF action may show macOS's permission UI. No development test should run this against a real capture service.
- `xcreen ask "QUESTION"` explicitly sends that question to the xCreen session. Captured evidence can reach a model provider, and Hermes/provider history may outlive the seven-day retention.
- Configuring a vault enables the scoped note writer; don't configure it without understanding that boundary.
- On macOS 26+, Spotlight offers "Ask xCreen" (fills the question in; you submit) and "Open xCreen". Spotlight picks them up after the installed app has launched once.

## Uninstall

Mac app:

```sh
xcreen stop
rm -rf ~/Applications/xCreen.app ~/.local/bin/xcreen
defaults delete dev.xcreen.app
```

Server on macOS: `launchctl bootout gui/$(id -u)/dev.xcreen.server && rm ~/Library/LaunchAgents/dev.xcreen.server.plist`. Server on Linux: `systemctl --user disable --now xcreen-server && rm ~/.config/systemd/user/xcreen-server.service`. Then remove `~/.local/bin/xcreen-server` and `~/.local/share/xcreen/app`.

Optionally remove the data after stopping: `~/Library/Application Support/xCreen` (evidence and outbox), `~/.local/share/xcreen/evidence` (Linux server), `~/.config/xcreen` (server config and token), `~/Library/Logs/xCreen` and `~/.xcreen-control`. This does not delete Hermes history, vault notes, backups or provider retention.

See the [CLI reference](docs/cli.md), [protocol](docs/protocol.md) and [implementation limits](docs/implementation-progress.md).
