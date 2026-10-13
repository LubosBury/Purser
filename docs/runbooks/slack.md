# Runbook: Slack webhook

Slack is an optional notification channel and is set per workspace (`slackWebhookEnabled` in the workspace configuration, the webhook URL in the Keychain under the account `slack-webhook.<workspace id>`). Without Slack, Purser sends only macOS notifications.

## What Purser sends

| Message | When |
|---|---|
| New findings | after a sync, only newly created ones, grouped rule × product |
| Apply finished or paused | the end of an apply, or a pause with its reason (RATE, AUTH, AGREEMENT, …) |
| Daily audit fingerprint | after the nightly sync: workspace, `seq` and `hash` of the chain head, no prices; in the audit as a `chainHeadPublished` event |

The webhook URL is a secret: whoever knows it can post messages to the channel (not read them). It belongs only in the Keychain, never in the repo, a chat or the shell history.

## Setup

1. Channel: create a private Slack channel for the workspace, e.g. `#purser-myapp`. One channel per workspace; messages of two workspaces do not mix.
2. Slack app: https://api.slack.com/apps → Create New App → From scratch → App Name `Purser <workspace name>` → choose the Slack workspace → Create App. One Slack app per Purser workspace, so that revoking one does not affect the others.
3. Incoming Webhooks → Activate Incoming Webhooks: On → Add New Webhook to Workspace → choose the channel from step 1 → Allow.
4. Copy the new webhook (the URL is only in the clipboard).
5. Verify the webhook without putting the URL in the command (only `$(pbpaste)` stays in the shell history):
   ```sh
   curl -sS -X POST -H 'Content-type: application/json' --data '{"text":"Purser: webhook test"}' "$(pbpaste)"; echo
   ```
   Expected output: `ok` and a message in the channel.
6. Purser → open the workspace → Settings → Slack → paste the URL → Save webhook → Touch ID; turn on Send messages to Slack → Save changes. The audit records `configChanged` (without the URL).
7. Clear the clipboard:
   ```sh
   pbcopy < /dev/null
   ```

## Verification

- The next morning the channel has the daily fingerprint with `seq` and `hash`.
- Purser → History: the last `chainHeadPublished` event has the same `seq` and `hash`.
- Against an audit export ([backup-restore.md](backup-restore.md)): `swift Tools/verify-audit-export.swift <export.jsonl> --check <seq>:<hash>` prints `check <seq>: OK`.

## Turning off, replacing, a leak

| Situation | Procedure |
|---|---|
| Turn notifications off | workspace Settings → Slack → turn off → Save changes; then Slack app → Incoming Webhooks → Remove at the webhook |
| Replace the webhook (e.g. another channel) | steps 3-7 for the new webhook, then Remove the old one |
| The URL leaked (chat, log, screenshot) | Slack app → Remove at once; a new webhook by steps 3-7; go through the channel for messages that are not yours |
| The workspace is being retired | Slack app → Basic Information → Delete App |

## Webhook errors

| Response | Meaning | What to do |
|---|---|---|
| `400 invalid_payload` | bad JSON | only in the manual test: fix `--data` |
| `403 action_prohibited` | the Slack admin has disabled webhooks | ask the Slack admin |
| `404 no_service` | the webhook was removed or revoked | a new webhook (steps 3-7) |
| `404 channel_not_found` | the channel does not exist | a new webhook into an existing channel |
| `410 channel_is_archived` | the channel is archived | restore the channel, or a new webhook |
