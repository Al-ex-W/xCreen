# Installing xCreen

Requires macOS 14+, Xcode/Swift and Python 3, plus Hermes Agent (`hermes --print-runtime-command`). Do not edit Hermes auth/config, grant screen permissions, enable capture, inspect private vault contents or run inference to verify installation.

```sh
git clone https://github.com/Al-ex-W/xCreen.git
cd xCreen
bash scripts/install.sh --no-launch
```

The installer obtains Hermes's Python/source root from its official launcher, locates an optional vault using `OBSIDIAN_VAULT_PATH` or Obsidian metadata, builds and copies the app to `~/Applications`, pre-fills settings, and copies the standalone Python CLI to `~/.local/bin/xcreen`. Add that directory to PATH. `--vault "/absolute/vault/path"` overrides detection. Omit `--no-launch` to launch. Integrity defaults ON; a saved explicit preference is restored, but actual capture stays blocked until current safety gates pass. Startup never requests permissions.

The copied CLI and bundled runtime do not depend on the checkout. The installer uses a configured `XCREEN_SIGN_IDENTITY`, otherwise an available Apple Development identity, otherwise ad-hoc signing. This is not a notarized consumer release. A stable signing identity is needed to preserve grants across reinstalls.

## Verify without capture or inference

```sh
xcreen start
xcreen status
xcreen integrity get
xcreen settings show
xcreen models list
xcreen logs --no-follow
```

Status is read directly from the running app, not a stale file. It must report Integrity true and capture paused. Connecting/model inventory resumes only the dedicated xCreen session and runs no model request. If Hermes cannot connect, the CLI returns an error and the tray shows the connection failure; no answer is claimed. Avoid publishing local settings/log output because it may contain personal paths or identifiers.

## Change settings through the owner

```sh
xcreen settings set python /absolute/python3
xcreen settings set root /absolute/hermes-agent
xcreen settings set vault "/absolute/vault"
xcreen settings set vault "" # disables Daily-note writing
xcreen settings autodetect
xcreen connection reconnect
xcreen model select PROVIDER EXACT_MODEL_ID
```

Settings are persisted by the running app and its gateway reconnects; session identity is retained. Do not use `defaults write` as a parallel live control surface. The installer pre-fills defaults only while the app is stopped.

## User-only deliberate actions

- Integrity OFF in the tray or `xcreen integrity off` explicitly consents to capture. The same actual service runs permission/state/exclusion gates for both interfaces. Permission denial leaves the user's desired switch unchanged and reports capture blocked; an explicit OFF action may show macOS's permission/settings UI. Do not bypass it. No development test should execute this action against a real capture service.
- `xcreen ask "QUESTION"` explicitly authorizes that question in the xCreen session. Captured evidence can reach a model provider, and Hermes/provider history may outlive local seven-day retention.
- Configuring a vault enables the scoped source-bound writer for existing Daily notes; do not configure it without understanding that boundary.
- The macOS 26+ Ask xCreen action opens a reviewed question handoff. Installed Spotlight discovery/ranking is not guaranteed or yet system-verified.

## Uninstall

```sh
xcreen stop
rm -rf ~/Applications/xCreen.app
rm -f ~/.local/bin/xcreen
defaults delete dev.xcreen.app
```

Optionally remove `~/Library/Application Support/xCreen`, `~/Library/Logs/xCreen`, and `~/.xcreen-control` after stopping. This does not delete Hermes history, vault notes, backups or provider retention.

See [CLI parity](docs/cli-parity.md) and [implementation limits](docs/implementation-progress.md).
