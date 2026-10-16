# Runbook: backup and restore

## What lives where

| Data | Where | Backup |
|---|---|---|
| `workspaces.json` (only id, name, color, directory) and each workspace's directory with `purser.sqlite`, `purser.sqlite-wal`, `purser.sqlite-shm` | the registry root of a signed build in the App Group container: `~/Library/Group Containers/<Team ID>.com.lubosbury.purser/Library/Application Support/Purser/` (`workspaces.json` and the `ws-<uuid>` directories); the fallback root of an unsigned build, `Application Support/Purser`, is moved to the App Group by the first launch of a signed build; the command below shows the exact place | Time Machine |
| Audit (hash chain) | the `audit_event` table in each workspace's `purser.sqlite` | Time Machine + a monthly JSONL export |
| ASC key (`.p8`), Google token, Slack webhook, owner name | Keychain, `ThisDeviceOnly` | does not transfer to another Mac; it is set up again there |
| Catalog (prices, offers, price points) | `purser.sqlite` | Time Machine is enough; it is a copy of the ASC state and a Sync restores it |

Where the databases are (on first run macOS asks whether Terminal may read another app's data; allow it):

```sh
purser_dbs() {
  { find "$HOME/Library/Containers/com.lubosbury.purser" -name purser.sqlite 2>/dev/null
    find "$HOME/Library/Group Containers" -maxdepth 1 -name '*.com.lubosbury.purser' -print0 2>/dev/null \
      | xargs -0 -I{} find {} -name purser.sqlite 2>/dev/null; }
}
purser_dbs | while IFS= read -r DB; do
  printf '%s\n' "$DB"
  sqlite3 -readonly "$DB" <<'SQL'
SELECT '  ' || json_extract(config_json, '$.name') || ' | production=' || json_extract(config_json, '$.isProduction') FROM workspace;
SQL
done
```

## Time Machine setup (once)

1. System Settings → General → Time Machine: at least one destination with encryption on (the databases hold prices and plans, not secrets).
2. Verify that Purser's data is not excluded from the backup:
   ```sh
   tmutil destinationinfo
   tmutil isexcluded "$HOME/Library/Containers/com.lubosbury.purser"
   find "$HOME/Library/Group Containers" -maxdepth 1 -name '*.com.lubosbury.purser' -exec tmutil isexcluded {} \;
   ```
   Expected output: at least one destination; `[Included]` for both paths. If a path is `[Excluded]`: `tmutil removeexclusion "<the printed path>"`.
3. A manual backup before a risky change (a big plan, a macOS upgrade): no plan in Applying, Purser quit (Cmd+Q), outside the nightly sync hour; then
   ```sh
   tmutil startbackup --block
   ```

## Monthly audit export

1. Encrypted storage for the exports (once):
   ```sh
   hdiutil create -size 1g -fs APFS -encryption AES-256 -volname PurserBackups ~/PurserBackups.dmg
   ```
   (it asks for a password; store it in a password manager). Before an export `open ~/PurserBackups.dmg` mounts `/Volumes/PurserBackups`.
2. For each workspace: History → Verify chain. Expected observation: OK with the number of events. If Purser reports a break at a `seq`, do not export and continue with the Restore section.
3. History → Export JSONL… → save as `/Volumes/PurserBackups/purser-audit-<workspace>-<YYYY-MM-DD>.jsonl`.
4. An offline check of the export against the head in History and against the last daily fingerprint from Slack (`seq` and `hash` from the message):
   ```sh
   swift Tools/verify-audit-export.swift "/Volumes/PurserBackups/purser-audit-<workspace>-<YYYY-MM-DD>.jsonl" --check "<seq from Slack>:<hash from Slack>"
   ```
   Expected output: `OK chain: <N> events, seq 1...<N>, content hashes recomputed`, `head: <N>:<hash>` and `check <seq>: OK`. `<N>` is the number of events from step 2; the head in History is `<N+1>` after the export, because Purser records `exportPerformed` only after the file is saved. The script recomputes the hash of every line the same way as `AuditLog.verifyExport(at:)` (K3), verifies the chain's continuity and the match with the published fingerprint, so an export can be verified without Purser.
5. `hdiutil detach /Volumes/PurserBackups`. Exports are never deleted (they are small).

## Restore on the same Mac (damaged or deleted workspace data)

1. Quit Purser (Cmd+Q) and the login item:
   ```sh
   pgrep -fl Purser
   pkill -f 'PurserLoginItem'
   pgrep -fl Purser
   ```
   Expected output of the last command: nothing.
2. Rename the damaged workspace directory (the directory with `purser.sqlite` from the `purser_dbs` listing), so that nothing is overwritten for good:
   ```sh
   WS_DIR="$(dirname "<path to purser.sqlite from the listing>")"
   mv "$WS_DIR" "$WS_DIR.damaged-$(date +%Y%m%d)"
   ```
3. Finder → Go → Go to Folder (Cmd+Shift+G) → the parent directory of `$WS_DIR` (`dirname "$WS_DIR"`) → in the menu bar Time Machine → Browse Time Machine Backups → choose the last backup before the damage → select the workspace directory → Restore.
4. Launch Purser → unlock → open the workspace → History → Verify chain. Expected observation: OK with the number of events.
5. Compare the chain head (History) with the last known fingerprint (Slack or the last export): the `seq` of the restored head ≤ the `seq` of the fingerprint. The difference is the number of audit events lost between the backup and the damage; their content is in the newest JSONL export, if it is newer than the backup. Record the difference in the owner's log (outside the repo).
6. Plans: a plan that was in Applying in the backup is marked Paused (CRASH) by Purser after launch. Never resume a restored plan: the restored database does not know about writes made after the backup. Abort → on PartiallyApplied use Re-plan the rest (a new Draft from the fresh ASC state), on Cancelled create a new plan.
7. Catalog → Sync. Changes Purser wrote after the backup show up as EXTERNAL findings (the restored database does not have their items). Compare each with the export (`grep -n '<plan or cell id>' <export>.jsonl`) and acknowledge it with the reason "restore from backup <date>; change from plan <id> in the lost part of the audit".
8. When everything is verified, delete the damaged directory: `rm -rf "$WS_DIR.damaged-<YYYYMMDD>"`.

## Restore on a new Mac

1. Install Purser and transfer the data: Migration Assistant, or a Time Machine restore of the directories from the table above (the same procedure as Restore step 3).
2. `ThisDeviceOnly` Keychain items do not transfer. On first launch Purser asks for the audit name again.
3. For each workspace:
   - a new ASC key and revocation of the old one ([key-rotation.md](key-rotation.md), procedure A or B),
   - Google: workspace Settings → Google Sheets → sign in again,
   - Slack: a new webhook or pasting the existing one ([slack.md](slack.md)),
   - nightly sync: Purser Settings → turn on (registers the login item).
4. Verify the chain and Sync as in Restore steps 4-7.

## Restore drill (every quarter, on a test workspace)

1. `purser_dbs` → the path to the test workspace's database → `TEST_DB="<path>"`.
2. Time Machine → choose a backup at least a week old → the test workspace's directory → right click → Restore "…" to… → a new directory `~/PurserRestoreDrill`.
3. Check:
   ```sh
   DRILL_DB=$(find ~/PurserRestoreDrill -name purser.sqlite | head -1)
   sqlite3 -readonly "$DRILL_DB" 'PRAGMA integrity_check;'
   sqlite3 -readonly "$DRILL_DB" 'SELECT seq, hash FROM audit_event ORDER BY seq DESC LIMIT 1;'
   ```
   Expected output: `ok` and `<seq>|<hash>`. Then:
   ```sh
   sqlite3 -readonly "$TEST_DB" 'SELECT hash FROM audit_event WHERE seq = <seq from the previous output>;'
   ```
   Expected output: the same `hash`. The backup is therefore an exact beginning of the live chain.
4. `rm -rf ~/PurserRestoreDrill`; record the date of the drill in the owner's log.
