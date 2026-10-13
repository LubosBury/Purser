# Runbook: ASC key rotation

Applies to each workspace separately. Every workspace has its own key in the Keychain (account `asc-key.<workspace id>`), so rotating one workspace's key does not touch the others.

## When to rotate

| Trigger | Procedure |
|---|---|
| Planned, once every 12 months | A (team key) or B (individual key) |
| A person with access to the Mac or the right to manage keys in ASC leaves | A / B the same day |
| A suspected leak (a `.p8` found outside the Keychain, a lost or sold Mac, a key in a log, chat or screenshot) | C at once |
| A change of role or app access for the user of an individual key | B |
| A new Mac (`ThisDeviceOnly` Keychain items do not transfer) | A / B on the new Mac, revoke the old key |

## What a rotation means for plans

- A plan is bound to keyKind + keyId (+ issuerId) + appId + bundleId (rule A1). After a key change the preflight blocks every plan created earlier.
- Draft: Re-plan after the rotation; the new Draft gets the new binding.
- Applying and any pause: finish it (Resume) before the rotation, or Abort. Never rotate in the middle of an apply.
- Scheduled, Effective, Closed: effectiveness tracking runs through the sync (read only) and continues with the new key. Rolling back what was written is a new WITHDRAW plan with the new binding.
- The new key has its own hourly request budget (`X-Rate-Limit`).

## Prerequisites (all procedures)

1. Purser → open the workspace → History → plans in the Applying state: no plan in Applying or paused. If there is one: Resume to the end, or Abort (Abort first reads back the items in flight).
2. A temporary folder for the key outside the repo:
   ```sh
   mkdir -p -m 700 ~/PurserSecrets
   ```

## A. Team key (no downtime)

1. ASC (Account Holder or Admin) → Users and Access → Integrations → App Store Connect API → Team Keys → "+":
   - Name: `Purser <workspace name> <YYYY-MM>`
   - Access: App Manager (never Admin)
   - Generate → Download API Key (it can be downloaded only once)
   ```sh
   mv ~/Downloads/AuthKey_*.p8 ~/PurserSecrets/ && chmod 600 ~/PurserSecrets/AuthKey_*.p8
   ls -l ~/PurserSecrets
   ```
   The Key ID is in the file name (`AuthKey_<Key ID>.p8`) and in the key table; the Issuer ID is above the table.
2. Purser → workspace → Settings → App Store Connect API key: type Team, the new Key ID, the Issuer ID, Import a new .p8… → the file from `~/PurserSecrets` → Touch ID. The audit records a `configChanged` event.
3. Delete the file and verify that no copy is left anywhere:
   ```sh
   rm ~/PurserSecrets/AuthKey_*.p8
   ls -A ~/PurserSecrets
   mdfind -name AuthKey_
   ls ~/.Trash | grep -c AuthKey_
   ```
   Expected output: `ls` nothing, `mdfind` nothing, the last command `0`.
4. Verify the new key: the workspace banner shows the new Key ID; Catalog → Sync → state Complete.
5. Every Draft plan of the workspace: open → Re-plan.
6. ASC → Team Keys → the old key → Revoke → confirm. Its state in the table is Revoked.

## B. Individual key (a short downtime)

A user can have only one active individual key [T3-33], so the old one is revoked before the new one exists. Between step 1 and the end of step 3 the workspace can neither read nor write (a nightly sync in that window ends with an authorization error).

1. ASC signed in as the key's user (the dedicated Apple ID, not the account owner) → your name at the top right → Edit Profile → Individual API Key → Revoke.
2. In the same place Generate API Key → Download API Key → move the file as in A.1.
3. Purser → workspace Settings → App Store Connect API key: type Individual, the new Key ID, Issuer ID empty, Import a new .p8… → Touch ID.
4. Delete the file and verify as in A.3.
5. Verify and replan as in A.4 and A.5.

## C. Suspected leak

1. Revoke the suspected key in ASC at once (Team Keys → Revoke; an individual key can also be revoked by an Admin in Users and Access → Integrations → Individual Keys). The revocation takes effect immediately; do nothing else until it is done.
2. A new key by A (steps 1-5), or B (steps 2-5).
3. Find out whether someone wrote with the key: Catalog → Sync → Findings. Every EXTERNAL finding since the day of the suspicion is a change Purser did not make. Go through them against the audit export (History → Export JSONL…) and only then acknowledge them with a reason, or create a repair plan.
4. Record the incident outside the repo (the owner's log): date, workspace, when the key was revoked, which EXTERNAL findings were found.

## Checklist

- [ ] no plan in Applying or paused
- [ ] new key with the App Manager role (individual: the user limited to the app)
- [ ] `.p8` imported and deleted, `mdfind -name AuthKey_` finds nothing
- [ ] Sync: Complete, the banner shows the new Key ID
- [ ] Draft plans replanned
- [ ] old key Revoked
- [ ] the Key ID is not written to the repo; the rotation is evidenced by the `configChanged` event in the audit
