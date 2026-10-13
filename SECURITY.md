# Security policy

Purser holds App Store Connect API keys and writes prices to production, so security reports are taken seriously.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting: the repository's **Security** tab → **Report a vulnerability**. Describe what you found, how to reproduce it and what an attacker could do with it. You will get a reply within a week.

Never include a real `.p8` key, a token, a Slack webhook URL or real product ids and prices in a report or an issue.

## Scope

In scope: anything that lets Purser write to an app other than the workspace's app, write without Touch ID (other than over the MCP bridge while the owner's setting allows it, see [docs/runbooks/mcp.md](docs/runbooks/mcp.md)) or without an audit record, leak a key, token or webhook from the Keychain, or forge or silently alter the audit chain.

Out of scope: an attacker who already controls the unlocked Mac and its Touch ID, and the behaviour of Apple's services.

## Supported versions

Only the latest release is supported.
