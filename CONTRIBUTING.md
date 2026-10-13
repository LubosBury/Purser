# Contributing

Thanks for looking into Purser. It is maintained by one person in spare time, so small, focused changes are the easiest to accept. For anything bigger, open an issue first.

## Ground rules

- **Write safety comes first.** Only the code in `Packages/PurserCore/Sources/Executor` writes to App Store Connect, every write is audited before it leaves and after it returns, asks for Touch ID and is never retried automatically. The one opt-in exception to Touch ID is the MCP bridge ([docs/runbooks/mcp.md](docs/runbooks/mcp.md)). `ArchitectureTests` enforces part of this. A change that weakens any of it will not be merged.
- **No live trials against real apps.** The App Store Connect API has no sandbox. Tests run against `FakeASC`. Never put real keys, tokens, product ids or prices in code, fixtures, issues or pull requests.
- **A new App Store Connect path** is added to [docs/research/asc-api-paths.md](docs/research/asc-api-paths.md) first, gets its `AppGuard` rule and tests, and only then is called.
- **User-facing text is English**, written as plain string literals.
- **The look** follows [docs/design/README.md](docs/design/README.md); colors, spacing and fonts come from the generated tokens, never hard-coded values.

## Before you open a pull request

```sh
make test              # PurserCore tests; must stay green
make build             # the app compiles (unsigned)
make check-endpoints   # every documented ASC path exists in Apple's OpenAPI spec
python3 -I -m unittest discover -s Tools/tests
```

Commits follow Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `chore:`). The Xcode project is generated from `project.yml` by XcodeGen; do not commit `Purser.xcodeproj`.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
