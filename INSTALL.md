# Installing xCreen

Requires macOS 14+, Xcode/Swift and Python 3, plus an installed [Hermes Agent](https://github.com/NousResearch/hermes-agent) (check with `hermes --print-runtime-command`). xCreen uses your Hermes profile read-only and sends inference to whichever provider your selected route uses; local OCR does not make inference local. Do not edit Hermes auth/config, grant screen permissions, enable capture, inspect private vault contents or run inference to verify installation.

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
xcreen session visibility get
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
xcreen model default                       # show the xCreen session default
xcreen model select PROVIDER EXACT_MODEL_ID # also saves it as the xCreen default
```

Settings are persisted by the running app and its gateway reconnects; session identity is retained. The xCreen session default is Claude Haiku 5.5 on your Anthropic account (`anthropic` / `claude-haiku-5-5`) until you pick another configured route in the tray or with `xcreen model default PROVIDER MODEL`; it applies only to the xCreen session, never Hermes's global default, and an unavailable model is reported rather than replaced. Do not use `defaults write` as a parallel live control surface. The installer pre-fills defaults only while the app is stopped.

## User-only deliberate actions
The **Show session in Hermes** tray toggle defaults OFF (hidden). Use `xcreen session visibility on` or `off` to change that same persisted preference for the existing xCreen session. Offline changes remain pending until connection/resume applies them. `xcreen --json status` separates desired `sessionVisible`, last gateway-confirmed `actualSessionVisible` (absent when unknown), and `sessionVisibilityPending`. No profile defaults, session identity, Integrity preference or capture behavior change. Upgrading an existing install with no saved visibility preference applies hidden on its next connection, even if the session was previously manually unhidden.

- Integrity OFF in the tray or `xcreen integrity off` explicitly consents to capture. The same actual service runs permission/state/exclusion gates for both interfaces. Permission denial leaves the user's desired switch unchanged and reports capture blocked; an explicit OFF action may show macOS's permission/settings UI. Do not bypass it. No development test should execute this action against a real capture service.
- `xcreen ask "QUESTION"` explicitly authorizes that question in the xCreen session. Captured evidence can reach a model provider, and Hermes/provider history may outlive local seven-day retention.
- Configuring a vault enables the scoped source-bound writer for existing Daily notes; do not configure it without understanding that boundary.
- On macOS 26+, Spotlight offers "Ask xCreen" (asks for a question, then opens the panel with it filled in; you submit) and "Open xCreen". The build fails if Xcode's App Intents metadata lacks these App Shortcuts. Spotlight picks them up after the installed app is registered and launched once; indexing can take a minute and ranking is up to macOS.

## Uninstall

```sh
xcreen stop
rm -rf ~/Applications/xCreen.app
rm -f ~/.local/bin/xcreen
defaults delete dev.xcreen.app
```

Optionally remove `~/Library/Application Support/xCreen`, `~/Library/Logs/xCreen`, and `~/.xcreen-control` after stopping. This does not delete Hermes history, vault notes, backups or provider retention.

See the [CLI reference](docs/cli.md), [CLI parity](docs/cli-parity.md) and [implementation limits](docs/implementation-progress.md).
