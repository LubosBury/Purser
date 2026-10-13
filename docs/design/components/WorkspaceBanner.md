# WorkspaceBanner

A full-width bar in the workspace's color that always shows which app a change will land in; production workspaces use `danger-fill`.

**Use.** Pin it above the toolbar on every screen and repeat it at the top of the confirmation sheet. It carries the app name, platform, key ID and app ID. The color is the user's choice from the six `ws-*` tokens, except for a production workspace, which is always `pu-banner--production` (red) whatever color was picked.

**Consumer provides.** App name, platform, key ID, app ID, a color option, and a production flag.

**Rules.**
- Text is `on-accent` (white); every `ws-*` fill and `danger-fill` holds 5:1 or more with it.
- The color is not the only signal: production also adds the word PRODUCTION to the name.
- Key and app IDs use the `identifier` style (monospace).
- Never recolor the banner for status; status lives in badges.
