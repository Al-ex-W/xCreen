# Contributing

Read [AGENTS.md](AGENTS.md), [how it works](docs/how-it-works.md) and [the architecture](docs/architecture.md) first. Keep changes small and scoped. Use conventional commit subjects (`docs:`, `test:`, `feat:`, `fix:`); separate features from cleanups. Open a focused pull request using the template: problem, privacy impact, tests and remaining limitations. Participation follows the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md), not in public issues.

## Checks

```sh
swift test
python3 -m unittest discover -s bridge/tests -v
python3 -m unittest discover -s runtime/tests -v
(cd server && python3 -m unittest discover -s tests -t . -v)
python3 -m unittest discover -s Tests -p '*_test.py' -v
bash scripts/build-app.sh
```

CI (the [Verify workflow](.github/workflows/verify.yml)) runs all of these on macOS, and the server suite on Linux with Python 3.10-3.13. The server must stay standard-library only and run on Hermes's own Python. The fake gateway in `server/tests/fake_gateway.py` stands in for Hermes; never point tests at a real Hermes home (a synthetic `HERMES_HOME` makes Hermes rebuild its apps). Use `xcreen-server init --no-detect` in tests. Installed-Hermes integration tests skip there because `XCREEN_HERMES_ROOT` is not set. To run them locally, use Hermes's own Python and set `TMPDIR` to a private directory that is not under a symlink.

`bash scripts/render-screenshots.sh` regenerates `docs/assets/tray.png` and `docs/assets/social-preview.png` by rendering the real tray `Panel` offscreen with the synthetic `DemoTrayModel` (dev-only `XCreenScreenshots` target, not bundled). It never captures the screen; keep it that way and never commit real screenshots.

Test capture policy before implementing capture. macOS UI, Screen Recording consent, lock transitions and Spotlight discovery require real integration checks in addition to unit tests. Never exercise capture on another person's screen without explicit consent. Use synthetic test records, not screenshots or private vault fixtures. Keep live smoke runs with Integrity ON.

Do not include local settings, credentials, user observations, generated application bundles or build artifacts in commits. Report inference tests as provider-backed only when a real inference succeeded. Review dependency/source licenses before copying implementation; project references are research, not copied code.

Contributions are licensed under Apache-2.0. Preserve relevant copyright and attribution notices; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
