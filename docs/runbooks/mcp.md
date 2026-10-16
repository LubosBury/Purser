# Claude (MCP)

Purser can be driven from an MCP client on the same Mac, such as Claude Desktop: reading the catalog, findings and plans, building Draft plans and, when the owner allows it, applying them.

## How it works

| Part | Where | What it does |
|---|---|---|
| `purser-mcp` | `Purser Pricing.app/Contents/MacOS/purser-mcp` | The MCP server the client starts over stdio. It answers the handshake and the tool list itself and forwards every tool call to the app. It holds no key and never talks to App Store Connect. |
| Bridge socket | `mcp.sock` in the App Group container | A Unix socket (mode 600) the app listens on while the bridge is on. The app refuses a peer of another user. |
| `MCPToolRouter` | in the app | Runs each tool through the same session, planning model and apply controller the windows use. `AppGuard`, preflight, the confirmation rules and the audit apply unchanged. |

The tools work only while Purser is running, unlocked and has a workspace open. Opening or switching a workspace stays in the app (Touch ID). A tool call counts as activity for the inactivity lock.

## Setup

1. Purser › Settings › Claude (MCP): turn on **Let Claude control Purser**.
2. Press **Copy the Claude Desktop configuration** and merge the `purser` entry into `~/Library/Application Support/Claude/claude_desktop_config.json`:

   ```json
   {"mcpServers": {"purser": {"command": "/Applications/Purser Pricing.app/Contents/MacOS/purser-mcp"}}}
   ```

3. Restart Claude Desktop and ask it for `purser_status`.

## Writes without Touch ID

With only the first switch on, Claude reads and prepares Drafts; `apply_plan`, `resume_plan`, `create_products` and `clone_products` are refused and the plan is applied in the Purser window, with the confirmation sheet and Touch ID.

**Apply plans and create or clone products without Touch ID** (turning it on asks for Touch ID once) lets those four tools write. What still holds:

- `apply_plan` and `resume_plan` must carry the plan's confirmation: the typed workspace name (C1), the reason and the ticked risk classes (C2), the acknowledged exclusions. A wrong or missing field returns the plan to Draft with nothing written. `create_products` and `clone_products` take no confirmation: each checks its request and reads what App Store Connect already has before it writes anything.
- Every call that changes something is written to the audit as `mcpToolCalled` before it runs, with its arguments; a write carries `touchID: notAsked`. The `httpSent` and `httpReceived` events follow as for any apply.
- Nothing is retried automatically.

What no longer holds: a person at the Mac confirming each write. With this switch on, Claude applies plans of prices and texts, including a plan that creates a new version (App Store Connect cannot delete a version through the API), and creates and clones products, whose Product IDs can never be used again, not even after the product is deleted. A price change of an approved product takes effect without App Review, so the only review of a price plan is the one done in the conversation with Claude. The bridge does not know who is on the other end: any program running under your macOS account can start `purser-mcp` and call the tools. Turn the switch on only on a Mac where you would trust every such program with your prices, texts and products, and turn it off when you do not need it.

## Tools

| Tool | Access |
|---|---|
| `purser_status`, `list_products`, `get_prices`, `get_localizations`, `list_findings`, `list_plans`, `get_plan`, `apply_status`, `get_import_format` | read |
| `sync_catalog`, `create_regular_price_plan`, `create_iap_price_plan`, `create_intro_offer_plan`, `create_promo_offer_plan`, `create_localization_plan`, `export_import_template`, `create_import_plan`, `replan`, `cancel_plan`, `ack_findings`, `withdraw_written`, `replan_rest`, `close_plan`, `pause_apply`, `abort_plan`, `preview_new_products`, `preview_clone` | local (never writes to App Store Connect) |
| `apply_plan`, `resume_plan`, `create_products`, `clone_products` | writes to App Store Connect |

Not available over MCP: importing from Google Sheets, editing the import mapping, workspace settings and keys, the audit export.

## Texts (localizations)

`get_localizations` returns the localized texts Purser read at the last sync: name and description of each subscription and in-app purchase, name and custom app name of each subscription group, per locale. `products` takes Product IDs, ASC ids and `group:<reference name>`; an empty list means every product and group, and `locales` narrows the locales. Every owner lists its live version and, when one exists, its pending version (being prepared or in review, with its App Store Connect state); a pending row says whether the text is `changed`, `added` or `removed` against the live one. Customers see the live texts until Apple approves the pending version. `get_localizations` only reads; `create_localization_plan` changes texts through a Draft plan.

`create_localization_plan` takes `rows`, one per product or group and locale, in the shape of the localization table the app exports:

| Field | Meaning |
|---|---|
| `product` | Product ID or ASC id of a subscription or in-app purchase, or `group:<reference name>` (or `group:<ASC id>`); the `product` field of `get_localizations` can be passed unchanged |
| `locale` | App Store locale code (`en-US`, `cs`, `de-DE`, …); an unknown code is blocked by rule N2 |
| `name`, `description` | The texts of a subscription or in-app purchase |
| `name`, `custom_app_name` | The texts of a subscription group |

An empty or omitted field keeps the current text; Purser never removes a text or a locale. A row Purser cannot place (an unknown product, a description for a group, a custom app name for a product) refuses the whole call.

Both tools and the localization table name an owner the same way. The prefix `group:` is read in any case, and a name that belongs to more than one group or product (two groups with the same reference name, two products with the same Product ID, a Product ID equal to another product's ASC id) is refused with the way to name it: `group:<ASC id>` for a group, the ASC id for a product. `get_localizations` therefore reports such an owner by its ASC id in `product`, so that its output works as input.

Purser writes texts only into a version that is still in preparation (never submitted, or rejected). For a product or group whose only version is approved and that has no version in preparation, the plan first creates a new version (rule N5, confirmation C1); App Store Connect cannot delete a version through the API. While a version waits for review or is in review, Purser neither writes into it nor creates another (N1). Apply the Draft with `apply_plan` like any other plan; customers see the texts of a version in preparation only after it is submitted in App Store Connect and approved.

A plan that created a new version answers `get_plan`, `apply_plan`, `resume_plan` and `apply_status` with `ready_for_review`: the message *Ready for review: submit in App Store Connect* and the owners whose version waits there. Purser never submits a version for review. Both fields follow the latest synced catalog: while the version is in preparation but a text the plan did not write is not in it, the owner is listed under `incomplete_versions` instead (*Not ready: some texts were not written; re-plan the rest first (replan_rest).*). Once `replan_rest` wrote the rest and a sync shows it, the original plan lists the owner under `ready_for_review`. Neither field lists the owner once App Store Connect shows the version in review or approved.

A version POST never goes out twice: after a lost answer or a 5xx, Purser waits and reads until App Store Connect shows the version (the plan pauses NETWORK when the waits run out). On resume after a crash, a version POST whose version the read does not show is Stale with its texts skipped, because the version may exist already; sync and replan.

## Importing a price table

For more than a few prices Claude should hand Purser a whole table instead of typing prices into the per-product tools:

1. `export_import_template` returns the workspace's table as CSV in the layout of the saved import mapping, filled with what is live today, so an unedited table plans nothing. It never changes a saved mapping; only a workspace without one gets the default (one regular-price column per subscription).
2. Claude edits the prices and saves the CSV, or keeps it as text.
3. `create_import_plan` with `csv_path` or `csv_text` runs the same importer as the app: country names and currencies are checked (S1 to S3), prices are snapped to Apple's price points, check-only columns are compared with the live prices, and the result is one Draft for every product in the table. `validate_only` stops before the Draft.

The answer carries a `checks` block, so nothing depends on Claude remembering a rule:

| Check | What it reports |
|---|---|
| `file_read`, `table_sha256`, `rows_read` | which file the helper read and what the importer got |
| `import_verdicts` | the importer's verdicts; a BLOCK (unknown country, wrong currency, a value that is not a number) refuses the table and nothing is planned |
| empty cells | Over MCP an empty cell carries no value and the price stays; the cells are listed as a WARN. In the app's own import an empty cell in a written column still refuses the table. |
| `iap_manual_prices_removed` | An in-app purchase column replaces the whole schedule, so a territory with a manual price today and no value in the table loses it. Every such price is listed. |
| `territories_without_a_row` | territories of the catalog the table does not mention; nothing is planned for them |
| `check_differences` | check-only cells whose snapped value differs from the live price |

A mapping with other columns (intro offers, promotional offers, check-only columns) is made in the app; `get_import_format` shows the one in force. The app is sandboxed and cannot open a path it was not handed in an open panel, so for `csv_path` the helper reads the file and sends its text; it reads only `.csv` files up to 4 MB. The audit records the size of the table, the plan stores the table and its SHA-256.

## Cloning products

`preview_clone` (local) reads what the app has in App Store Connect and lists the steps; `clone_products` (writes) runs them after one approval: each clone gets its source's attributes (group and level, period, Family Sharing, review note), availability, texts and review screenshot. Then Purser syncs and builds the Drafts of each clone, all at the source's price tiers: one for the regular prices (UPFRONT), one introductory offer draft per offer shape (mode, length, number of periods and dates), one promotional offer draft per offer, and for an in-app purchase one for its current prices.

- Arguments: `products` (each `{source, product_id?, name?}`; the defaults are the source's Product ID and name followed by the suffix), `suffix` (also appended to the codes of copied promotional offers), `group` (`"source"` or `{"new": "<name>"}`), `level` (`source` or `end`), `copy` (a list of `localizations`, `review_screenshot`, `prices`, `intro_offers`, `promo_offers`; omitted = all).
- A Product ID can never be used again, not even after the product is deleted, and Purser cannot see deleted products: call `preview_clone` first.
- A new `clone_products` run with the same arguments adds only what is missing (a failed step, an upload that did not finish) and writes nothing that exists.
- The drafts are ordinary Drafts: review them with `get_plan` and apply them in the listed order, the regular prices first. When the clone and the sync together take longer than nearly three minutes (165 seconds), the answer says `"drafts": "preparing"` and `list_plans` shows them when it ends. A draft whose title a plan that has not ended already carries (a Draft, a Stale plan, or a plan that is Applying, Scheduled or PartiallyApplied) is not built again; its entry says `Draft already exists` while that plan is a Draft, and `Plan already exists` once it is not.
- MONTHLY plan types, scheduled price changes and future in-app purchase prices are not copied. The answer lists them under `not_copied`; while the drafts are not prepared yet (`"drafts": "preparing"`), `not_copied` says that the list is not worked out yet. Once the drafts exist, a new `clone_products` run with the same arguments returns the list: it writes nothing that exists and builds no draft twice.
- Purser runs one product creation or clone at a time: while one runs, from the window or over MCP, `create_products` and `clone_products` are refused and `preview_clone` answers “A clone is running in Purser; wait until it finishes.” (or that new products are being created) instead of listing steps. A clone runs until its price drafts are built, not only until its last write: the sheet's *Prepare price drafts* is refused as well while the drafts of a clone are being built.
- If the call ends with “Purser did not answer in time”, the clone is still running in the app. Wait until `preview_clone` no longer says that a clone is running (that includes the sync and the drafts, which the app finishes on its own); then the steps it lists are the ones that failed (no steps and nothing `blocked` means the clone is complete) and `list_plans` shows the drafts.
- `preview_clone` lists apart, under `blocked`, the steps a run cannot take now, each with its reason; `clone_products` reports them as failed and sends nothing for them. Today that is a review screenshot the clone already holds and Purser may not replace (an unfinished upload from an earlier run): the owner removes it in App Store Connect (the product's Review Information), then the clone runs again.
- The review screenshot is the only data Purser sends outside `api.appstoreconnect.apple.com`: the image is read from Apple's image CDN and uploaded to Apple's upload host, both over https and without the key; every upload is in the audit.
