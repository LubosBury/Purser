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

With only the first switch on, Claude reads and prepares Drafts; `apply_plan`, `resume_plan` and `create_products` are refused and the plan is applied in the Purser window, with the confirmation sheet and Touch ID.

**Apply plans and create products without Touch ID** (turning it on asks for Touch ID once) lets those three tools write. What still holds:

- The call must carry the plan's confirmation: the typed workspace name (C1), the reason and the ticked risk classes (C2), the acknowledged exclusions. A wrong or missing field returns the plan to Draft with nothing written.
- Every call that changes something is written to the audit as `mcpToolCalled` before it runs, with its arguments; a write carries `touchID: notAsked`. The `httpSent` and `httpReceived` events follow as for any apply.
- Nothing is retried automatically.

What no longer holds: a person at the Mac confirming each write. A price change of an approved product takes effect without App Review, so with this switch on the only review of a price plan is the one done in the conversation with Claude. The bridge does not know who is on the other end: any program running under your macOS account can start `purser-mcp` and call the tools. Turn the switch on only on a Mac where you would trust every such program with your prices, and turn it off when you do not need it.

## Tools

| Tool | Access |
|---|---|
| `purser_status`, `list_products`, `get_prices`, `list_findings`, `list_plans`, `get_plan`, `apply_status`, `get_import_format` | read |
| `sync_catalog`, `create_regular_price_plan`, `create_iap_price_plan`, `create_intro_offer_plan`, `create_promo_offer_plan`, `export_import_template`, `create_import_plan`, `replan`, `cancel_plan`, `ack_findings`, `withdraw_written`, `replan_rest`, `close_plan`, `pause_apply`, `abort_plan`, `preview_new_products` | local (never writes to App Store Connect) |
| `apply_plan`, `resume_plan`, `create_products` | writes to App Store Connect |

Not available over MCP: importing from Google Sheets, editing the import mapping, workspace settings and keys, the audit export.

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
