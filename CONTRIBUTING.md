# Contributing

Read [AGENTS.md](AGENTS.md) and [the architecture](docs/architecture.md) first. Keep changes small and scoped. Use conventional commit subjects (`docs:`, `test:`, `feat:`, `fix:`); separate features from cleanups. Open a focused pull request with the problem, privacy impact, tests and remaining limitations.

## Checks

```sh
swift test
python3 -m unittest discover -s bridge/tests -v
bash scripts/build-app.sh
```

Test capture policy before implementing capture. macOS UI, Screen Recording consent, lock transitions and Spotlight discovery require real integration checks in addition to unit tests. Never exercise capture on another person's screen without explicit consent. Use synthetic test records, not screenshots or private vault fixtures.

Do not include local settings, credentials, user observations, generated application bundles or build artifacts in commits. Report inference tests as provider-backed only when a real inference succeeded. Review dependency/source licenses before copying implementation; project references are research, not copied code.

Contributions are licensed under Apache-2.0. Preserve relevant copyright and attribution notices; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
