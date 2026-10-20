# Purser

Purser is a native macOS app for one user that plans, writes and verifies the prices of iOS apps in App Store Connect (ASC): regular prices of auto-renewable subscriptions, introductory offers, promotional offers and prices of one-time purchases (IAP, typically lifetime). The same way it writes the localized names and descriptions of subscriptions, in-app purchases and subscription groups, and it clones products for A/B tests: a clone gets its source's attributes, availability, texts and review screenshot, and the source's prices and offers come as Draft plans. Submitting for review stays one click in App Store Connect.

Every change takes the same path: import from a Google Sheet or a CSV, or a rule → diff against the live ASC state → check of Apple's rules → stronger confirmation for risky changes → write item by item → verification by reading back → a record in the append-only audit.

> **Purser writes to production.** The App Store Connect API has no sandbox: every price Purser writes is a real price in your live app, and every text it writes goes into your app's real records in App Store Connect. A new version Purser creates to change the texts of an approved product cannot be deleted through the API, and the Product IDs of a clone can never be used again, not even after the clone is deleted. Review each plan before you apply it, start with one territory (the CANARY flag), and keep the first writes on a subscription group that is never submitted for review. The software is provided as is, without warranty of any kind (see [LICENSE](LICENSE)); you are responsible for the changes it makes in your account.
>
> Purser is an independent project. It is not affiliated with, endorsed by or sponsored by Apple Inc. App Store Connect, App Store and TestFlight are trademarks of Apple Inc.

## Tested on a real app

Purser was developed and tested on the maintainer's own app, [Juice: Fuel & EV Charge Log](https://apps.apple.com/app/juice-fuel-ev-charge-log/id6787720329). The specification and the spike records in `docs/` call it Juice. The spikes ran in its "Purser Spike" subscription group, which is never submitted for review. The text and cloning writes added in 1.2 have since been used in production on Juice; spike SL10n ([docs/spikes/SL10n.md](docs/spikes/SL10n.md)), which records Apple's exact answers to those requests, is not written up yet.

Spike S10 ([docs/spikes/S10.md](docs/spikes/S10.md)) confirmed on 2026-10-16 that a POST of an in-app purchase's price schedule replaces the whole schedule, future prices included. Since 1.3 Purser writes in-app purchase schedules that already have manual prices; rule S10 and its exception S10a no longer block anything. A territory whose manual price a plan removes moves to the price Apple derives from the base territory in the same request, which the plan shows as a warning (L2).

## Install

Download the latest notarized build from the [Releases](../../releases) page, move `Purser Pricing.app` to Applications and open it. It needs macOS 15 or later and a Mac with Touch ID. On first launch Purser asks for the name it records in the audit as the actor; it can be changed in Settings behind Touch ID.

Then add your app as a workspace: [docs/runbooks/new-workspace.md](docs/runbooks/new-workspace.md).

## Claude Desktop (MCP)

Purser can be driven from an MCP client on the same Mac, such as Claude Desktop: reading prices, texts, findings and plans, importing a price table, building Draft plans and, if you allow it, applying them and creating or cloning products. It is off by default.

1. Purser › Settings › Claude (MCP): turn on **Let Claude control Purser**.
2. Press **Copy the Claude Desktop configuration** and merge the `purser` entry into `~/Library/Application Support/Claude/claude_desktop_config.json`.
3. Restart Claude Desktop and ask it for the Purser status.

A second switch, **Apply plans and create or clone products without Touch ID**, lets Claude write to App Store Connect. Read [docs/runbooks/mcp.md](docs/runbooks/mcp.md) first: it lists every tool and what that switch gives up.

## Name

The app shows itself to the user as **Purser Pricing** (the name "Purser" is taken in the App Store): the bundle `Purser Pricing.app`, the menu bar, the window title, the record in App Store Connect. The project, the repo, the modules, the process (`Purser`) and the bundle ID (`com.lubosbury.purser`) keep the short name Purser.

## Principles

- The ASC key (`.p8`) never leaves the Mac: it lives only in the Keychain (`ThisDeviceOnly`); Touch ID at launch and before every write. The one exception is opt-in: writes asked for over the [MCP bridge](docs/runbooks/mcp.md) while the owner's setting allows them.
- Every iOS app has its own, fully separate workspace (database, key, settings). Writing to the wrong app must be impossible, not just unlikely.
- The ASC API has no sandbox; every write goes to production. Spikes and first writes run only on a test subscription group that is never submitted for review.
- Nothing in the code is specific to one app; everything is workspace configuration.
- Only the code in `Sources/Executor` writes to ASC. In a Release build that is a plan that passed preflight and confirmation (`Executor`), or a product creation or clone that checked its request and read what App Store Connect already has (`ProductCreator`); a Debug build adds two narrow probes for spikes: `SpikeProbe` lets through only ids from the "Purser Spike" test group, `ApprovedProbe` (not implemented yet, it comes only after OQ1 is approved in writing) only the OQ1 probes. Every write is preceded by an `httpSent` event in the audit.
- Apart from the ASC API, only `AssetTransfer` (in `Sources/Executor`) talks to Apple, to copy a clone's review screenshot: it downloads from Apple's image CDN and uploads to Apple's upload hosts, https only, without the key and without following a redirect, and every upload is in the audit.
- The tools in `Tools/` send only GET with a GET-scoped token; no script and no curl holds a token usable for a write.

## Building from source

The released build is signed by the maintainer. To build and sign your own you need an Apple Developer Program membership and your own bundle IDs: replace `com.lubosbury` in `project.yml`, the three `.entitlements` files, `App/Info.plist` and the Swift sources, and register the App IDs with App Groups and Keychain Sharing.


| What | Note |
|---|---|
| macOS 15 or later | deployment target 15.0 |
| Xcode with Swift 6 and the macOS 15 SDK | Swift 6 language mode, Swift tools 6.0 |
| XcodeGen | `brew install xcodegen` |
| Apple Developer Program | App ID `com.lubosbury.purser` (App Groups, Keychain Sharing) and `com.lubosbury.purser.LoginItem` |
| `Config/Signing.local.xcconfig` | a copy of `Config/Signing.local.xcconfig.example` with `DEVELOPMENT_TEAM`; not in git |
| An ASC key for each workspace | [docs/runbooks/new-workspace.md](docs/runbooks/new-workspace.md) |
| Google Cloud OAuth client (optional) | type iOS, bundle id `com.lubosbury.purser`; only for the import from Google Sheets |

### First setup

In the root of the cloned repository:

```sh
brew install xcodegen
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
open -e Config/Signing.local.xcconfig     # fill in DEVELOPMENT_TEAM = <Team ID from developer.apple.com>
make generate
```

### Build, tests, running

| Command | What it does |
|---|---|
| `make generate` | XcodeGen generates `Purser.xcodeproj` from `project.yml` |
| `make test` | tests of the PurserCore package (`swift test --package-path Packages/PurserCore`, Swift Testing) |
| `make build` | generate + an unsigned Debug build (`CODE_SIGNING_ALLOWED=NO`); checks that everything compiles |
| `make check-endpoints` | checks the ASC paths listed in `docs/research/asc-api-paths.md` against OpenAPI 4.5.1 |
| `make archive` | a Release archive signed by the team from `Signing.local.xcconfig` (only from a clean tree) |
| `make testflight` | archive + export and upload to App Store Connect (TestFlight, internal testing only) |
| `make release` | a Developer ID build, notarized and packed as a DMG in `build/release/` (needs a `notarytool` keychain profile named `purser-notary`) |

Running during development: the unsigned build from `make build` has no sandbox and no shared Keychain. Open `Purser.xcodeproj` in Xcode, scheme `Purser`, Run (it is signed with the team's Apple Development certificate). For everyday use install a build from TestFlight.

The dev build and the TestFlight build share the bundle id and therefore the data (container, App Group, Keychain). Never run both at once.

### TestFlight (maintainer)

1. Once: a macOS app record in ASC (bundle id `com.lubosbury.purser`) and an internal group `Purser Internal` with automatic distribution.
2. Commit all changes (only a clean tree is archived; build number = `git rev-list --count HEAD`).
3. `make testflight` → `** EXPORT SUCCEEDED **`.
4. ASC → TestFlight: after processing, the `Purser Internal` group gets the build; on the Mac, TestFlight → Install.
5. Smoke test. A TestFlight build expires after 90 days.

## Operations

| Runbook | When |
|---|---|
| [New workspace](docs/runbooks/new-workspace.md) | adding another iOS app |
| [ASC key rotation](docs/runbooks/key-rotation.md) | planned rotation, a person leaving, a suspected leak, a new Mac |
| [Backup and restore](docs/runbooks/backup-restore.md) | Time Machine, monthly audit export, chain verification, restore |
| [Slack webhook](docs/runbooks/slack.md) | notifications and the daily audit fingerprint |
| [Claude (MCP)](docs/runbooks/mcp.md) | driving Purser from Claude Desktop, and what writing without Touch ID gives up |

## Documentation

| Document | Content |
|---|---|
| [docs/specs/2026-10-09-purser-v1-design.md](docs/specs/2026-10-09-purser-v1-design.md) | v1 design: scope, decisions, architecture, data model, life cycle of a change, rules, screens, spikes |
| [docs/specs/2026-10-14-localizations-and-cloning-design.md](docs/specs/2026-10-14-localizations-and-cloning-design.md) | 1.2 design: localized texts through plans, new versions of approved products, cloning products; known limitations |
| [docs/research/asc-api-facts.md](docs/research/asc-api-facts.md) | verified facts about the App Store Connect API |
| [docs/research/asc-api-paths.md](docs/research/asc-api-paths.md) | every App Store Connect API path Purser calls |
| [docs/design/README.md](docs/design/README.md) | design system: dark, black ground, glass, native components; tokens in `docs/design/tokens.json`, generated Swift tokens in `App/Shared/Design/` |
| [docs/spikes/](docs/spikes/) | spike results; each changes at most a constant in `AppleConstants` |

## Repository structure

| Path | Content |
|---|---|
| `App/` | the SwiftUI app (target `Purser`) |
| `LoginItem/` | the login item for the nightly sync (target `PurserLoginItem`) |
| `MCPHelper/` | `purser-mcp`, the stdio MCP server that forwards tool calls to the running app (target `PurserMCP`) |
| `Packages/PurserCore/` | the core: Domain, Store, Audit, PurserSecurity (folder `Sources/Security`), ASCClient, Catalog, Importer, Policy, Planner, Executor, Background, MCPBridge, MCPTools and the tests |
| `Config/` | xcconfig, `ExportOptions.plist` |
| `Tools/` | `check-asc-endpoints.py`; `mint-token.swift`, `record-fixture.sh` and `redact-fixture.py` (recording GET responses and redacting fixtures); `asc-readonly-get.swift` (GET only with a GET-scoped token, for key spikes); `verify-audit-export.swift` (offline check of an audit export) |
| `docs/` | spec, research, spikes, runbooks |

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Support

Purser is free and maintained in spare time. If it saves you an afternoon of clicking in App Store Connect, you can [sponsor the maintainer on GitHub](https://github.com/sponsors/LubosBury).

## License

MIT, see [LICENSE](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
