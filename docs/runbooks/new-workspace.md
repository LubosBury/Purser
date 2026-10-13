# Runbook: new workspace

One workspace = exactly one iOS app (decision D3). Workspaces share nothing: not the database, the key, the Google account, the Slack webhook or the settings. A new app is added to Purser by configuration only; if a particular app seems to need a code change, that is a Purser bug, not a configuration task (D5).

## Prerequisites

- The app exists in ASC and has the subscription groups or IAPs you want to manage.
- The Account Holder has accepted the current Paid Apps Agreement (otherwise an apply ends in the AGREEMENT pause, rule A8).
- You have the Account Holder or Admin role in the app's ASC account (for keys and users).
- Purser is installed and unlocked.

## 1. Key type

| App | Key | Why |
|---|---|---|
| Production (paying customers) | an individual key of a user with the App Manager role limited to this app only | the only documented key limited to one app [T3-32, T3-33]; verified by spike S9 |
| Personal or test | a team key with the App Manager role | a team key sees every app of the account; acceptable only where a wrong write cannot reach paying customers |

Always the App Manager role, never Admin. One key belongs to one workspace and is not shared with other tools (it would share the hourly request budget).

## 2a. Individual key (production app)

1. ASC (Admin) → Users and Access → People → "+":
   - Email: a dedicated Apple ID (not your main one; a user with the Admin role cannot be limited to an app)
   - Roles: App Manager only
   - Apps: Specific apps → this app only
   - Additional permissions: Generate Individual API Keys
   - Invite
2. Accept the invitation in the dedicated Apple ID's mailbox and sign in to ASC with it (two-factor authentication).
3. As this user: your name at the top right → Edit Profile → Individual API Key → Generate API Key → Download API Key.
4. Move the key out of Downloads:
   ```sh
   mkdir -p -m 700 ~/PurserSecrets
   mv ~/Downloads/AuthKey_*.p8 ~/PurserSecrets/ && chmod 600 ~/PurserSecrets/AuthKey_*.p8
   KEY=$(find ~/PurserSecrets -name 'AuthKey_*.p8' | head -1); KEY_ID=$(basename "$KEY" .p8); KEY_ID=${KEY_ID#AuthKey_}; echo "$KEY_ID"
   ```
5. Verify the key's limits (from the repo root; one GET):
   ```sh
   swift Tools/asc-readonly-get.swift --key "$KEY" --key-id "$KEY_ID" --out /dev/null '/v1/apps?fields[apps]=bundleId,name&limit=200'
   ```
   Expected output: `HTTP 200` and `data: 1 resource(s): <the app's Apple ID>`. More apps = the user is not limited; fix Apps in ASC, revoke the key and start again at step 3.

## 2b. Team key (personal or test app)

1. ASC → Users and Access → Integrations → App Store Connect API → Team Keys → "+" → Name `Purser <app> <YYYY-MM>`, Access App Manager → Generate → Download API Key.
2. Move the file as in 2a.4. The Issuer ID is above the key table.

## 3. App details

| Field | Where in ASC |
|---|---|
| App ID | Apps → the app → App Information → General Information → Apple ID (a number) |
| Bundle ID | the same place, Bundle ID |

## 4. Creating it in Purser

Workspace picker → New workspace…:

| Field | Value |
|---|---|
| Name | the app's name; in a production workspace the C1 confirmation asks you to type it |
| Color | different from the other workspaces |
| Production | turn on for an app with paying customers: a red banner and C1 at every apply (A2) |
| App ID, Bundle ID | from step 3; at every apply the preflight compares them with a live `GET /v1/apps/{id}` (A1) |
| Key type | Individual (2a) or Team (2b) |
| Key ID | from step 2 |
| Issuer ID | team key only |
| Key (.p8) | Choose .p8… → the file from `~/PurserSecrets` |
| Nightly sync (UTC hour) | a different hour from the other workspaces |

Create workspace → Touch ID. Then delete the key from the disk:

```sh
rm ~/PurserSecrets/AuthKey_*.p8
ls -A ~/PurserSecrets
mdfind -name AuthKey_
```

Expected output: nothing from the last two commands.

## 5. First sync

- Open the workspace and check the banner: color (red for production), key type, Key ID, App ID.
- Catalog → Sync → state Complete. All rows have the provenance BASELINE.
- INVARIANT findings after the first sync are real problems of the current state in ASC (for example an intro more expensive than the regular price, I4). Do not fix them at once; solve them with a repair plan after step 7.

## 6. Import and notifications (optional)

- Google: workspace Settings → Google Sheets → OAuth client ID (Google Cloud, type iOS, bundle id `com.lubosbury.purser`; the client id may be the same as in another workspace, the token always belongs to this workspace only) → Sign in with Google → a Google account allowed to read the sheet.
- Import mapping: country column, currency column, first data row, targets (column → product × price type; nominal discount for discounts; writes / check only). Every configuration change goes to the audit (`configChanged`).
- Slack: [slack.md](slack.md).

## 7. First plan

- The first write in a new workspace is always a canary: New plan → filter to 1 product and 1 territory, the CANARY flag → Build plan → go through the diff → Apply (Touch ID → preflight → confirmation).
- Wait for Scheduled or Effective and for a verify without Mismatch; only then run bigger plans.
- In a production workspace where you are not sure about the configuration, let the first plan go only as far as the confirmation sheet and cancel it there (Cancel → the plan stays a Draft, 0 writes).

## Checklist

- [ ] key type by the table in step 1; App Manager role
- [ ] individual key: `GET /v1/apps` returns this app only
- [ ] `.p8` imported and deleted, `mdfind -name AuthKey_` finds nothing
- [ ] Production turned on for an app with paying customers
- [ ] the banner shows the right App ID, key type and Key ID
- [ ] first sync Complete, provenance BASELINE
- [ ] nightly sync at a different hour from the other workspaces
- [ ] first plan as a canary
