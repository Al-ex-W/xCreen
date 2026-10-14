# Installing xCreen (instructions for agents)

This guide is written for an AI agent (Hermes, Codex, …) installing xCreen on the
user's Mac. Follow it top to bottom. Every step either runs a command or names the
one action only the user can do.

## 0. Requirements

| Need | Check |
|---|---|
| macOS 14 or newer | `sw_vers -productVersion` |
| Swift toolchain | `swift --version` (else `xcode-select --install`, then the user accepts the dialog) |
| Hermes Agent installed | `hermes --print-runtime-command` prints a JSON argv |
| Obsidian vault (optional) | Needed only for automatic Daily-note writing |

If Hermes is missing, stop and tell the user. xCreen uses Hermes for all model access.

## 1. Install

```sh
git clone https://github.com/Al-ex-W/xCreen.git
cd xCreen
bash scripts/install.sh            # add --vault "/abs/path/to/vault" to override detection
```

The script:

1. Asks the `hermes` launcher for its own Python and source root (`--print-runtime-command`).
2. Picks the vault: `OBSIDIAN_VAULT_PATH` if set, otherwise Obsidian's vault list. A vault
   with a `Daily/` folder wins, then the open vault, then the most recently used one.
3. Builds `dist/xCreen.app`, copies it to `~/Applications/xCreen.app` and launches it.
4. Writes the detected paths to the app's preferences, so **Local settings is already
   filled in**.

The script prints the chosen paths. Show them to the user. If the vault is wrong,
rerun with `--vault`.

The app also auto-detects on first launch, and **Local settings → Auto-detect** reruns
detection. You only need the script to install and to pre-fill the settings.

## 2. Verify

```sh
xcreen status          # app, gateway, Hermes connection, Integrity, capture, evidence counts
xcreen logs            # live activity log (Ctrl-C to stop)
xcreen logs --gateway  # Hermes gateway stderr, for connection problems
defaults read dev.xcreen.app | grep -E 'xcreen\.(hermes|vault)'
```

`xcreen status` must show `hermes connected`. If it shows `failed: …`, read
`xcreen logs --gateway`.

All three keys (`xcreen.hermes.python`, `xcreen.hermes.root`, `xcreen.vault.path`) should
point at existing paths. The vault key is absent if no vault was found.

## 3. Steps only the user can do

Tell the user to do these. Do not click through permission prompts for them.

1. **Turn Integrity mode off** in the menu-bar panel. The first time, macOS asks for
   Screen Recording permission (or xCreen opens that settings pane). After the user allows
   xCreen, they turn Integrity off again and capture starts.
2. Grants survive reinstalls only when the app has a stable signature. `install.sh` uses
   the first "Apple Development" identity it finds, or `XCREEN_SIGN_IDENTITY`. Ad-hoc
   builds lose the grant on every rebuild.
3. **Optional: Spotlight.** ⌘-Space, then type a question. "Ask xCreen" appears as an
   App Shortcut.
4. **Optional: Daily notes.** The vault writer only appends to a `Daily/YYYY-MM-DD.md`
   note that already exists. It never creates notes.

## 4. Pick a model

Open the panel and ask any question once. The model picker then lists every model
configured in Hermes. Switching changes only the xCreen session, never Hermes defaults.
A light model with vision (for example a Haiku-class model) is recommended, because
xCreen sends 30 screenshots every 5 active minutes.

## Overrides

```sh
defaults write dev.xcreen.app xcreen.hermes.python -string /abs/python3
defaults write dev.xcreen.app xcreen.hermes.root   -string /abs/hermes-agent
defaults write dev.xcreen.app xcreen.vault.path    -string "/abs/vault"
defaults delete dev.xcreen.app xcreen.vault.path   # disable Daily-note writing
```

## Uninstall

```sh
pkill -x xCreen; rm -rf ~/Applications/xCreen.app
defaults delete dev.xcreen.app
rm -rf ~/Library/Application\ Support/xCreen   # local screenshots and OCR (7-day retention)
```

## Rules for the installing agent

- Do not edit Hermes config, profiles or credentials. xCreen needs none of that.
- Do not grant permissions or toggle Integrity for the user.
- Do not read the vault contents. Locating the vault folder is enough.
