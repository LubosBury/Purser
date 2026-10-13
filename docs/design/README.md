Purser is a native macOS app (SwiftUI) for reviewing and applying price changes in App Store Connect. The interface is calm, dark and precise: black ground, glass surfaces, system type, system controls. Build every screen from these rules and the tokens named in them.

## Principles

- **Native first.** Use the platform's own controls (Button, Table, Picker, Toggle, List sidebar, sheets) and style them with these tokens. Recreate a control from scratch only when the system has none.
- **Black, then glass.** The window is `canvas` (#000000). Content groups sit on glass: `glass-fill` with `glass-border`, `shadow-glass` and `blur-md`. Glass lives on black or on `pu-stage`, never on a light or opaque grey ground.
- **Numbers are the content.** Prices, deltas and counts are set in `figure` (monospace, tabular, right-aligned). Chrome stays quiet so the numbers carry the screen.
- **Risk is loud, everything else is quiet.** Only BLOCK, WARN, Paused and the production banner use saturated color. A screen with no problems is black, glass and white text.

## Visual foundations

**Color.** Text is `text-primary` for content, `text-secondary` for labels and column headers, `text-tertiary` for captions and hints. Grounds are `canvas`, `surface-1`, `surface-2`, `surface-3` (opaque) and `glass-fill` through `glass-fill-pressed` (translucent). All text tokens hold 4.5:1 on every ground up to `glass-fill-hover`; do not set `text-tertiary` on `glass-fill-pressed`.

**Accent.** `accent` (#0a84ff) is for the focus ring, progress fill, selection marker and icons. Links and text buttons use `accent-text`. The primary button uses `accent-fill` with `on-accent` text. There is one primary button per screen or sheet.

**Status.** `success`, `warning`, `danger` and `info` appear as text and icon on their `-tint` backgrounds, always with a word (Verified, WARN, BLOCK) and an icon of a different shape. Do not tell success from danger by hue alone. `danger-fill` is reserved for the production banner and destructive buttons.

**Workspace color.** Each workspace picks one of the `ws-*` tokens for its banner. Production overrides the choice with `danger-fill` and adds the word PRODUCTION.

**Glass.** Resting fill `glass-fill`, hover `glass-fill-hover`, pressed `glass-fill-pressed`. Panels use `radius-lg`; sheets use `radius-xl`, `shadow-sheet` and `blur-lg`. Do not stack glass on glass; separate rows inside a panel with `separator`. When Reduce Transparency is on, panels become opaque `surface-2` and sheets `surface-3`. On macOS 26 use `.glassEffect` in a `GlassEffectContainer`; before that use `.ultraThinMaterial`.

**Type.** The system font (SF Pro) via `font-sans`; no font files are shipped. Screen titles use `title-large`, panel titles `title-2`, body and table cells `body`, column headers `headline`, hints `footnote`. IDs and hashes use `identifier`. Do not use more than three sizes on a screen.

**Spacing and radii.** A 4px grid: `space-1` to `space-10`. Panel padding `space-4`, gap between panels `space-4`, sheet padding `space-5`, table cell padding `space-2` by `space-3`. Controls use `radius-sm`, tables `radius-md`, panels `radius-lg`, sheets `radius-xl`, badges and progress `radius-pill`.

**Focus.** Keyboard focus is `shadow-focus`: a black gap and a 2px `accent` ring, 3:1 or more on every ground. It is never removed.

**Motion.** Short and functional: 150 to 250 ms ease-out for hover, selection and sheet presentation. No looping animation except a determinate progress bar. Honor Reduce Motion by cutting transitions to a fade.

**Borders and shadows.** A panel's edge is its fill, a 1px `glass-border` and a 1px top highlight inside `shadow-glass`. Controls that take input (fields, checkboxes, segmented control) use `border-control` so their edge holds 3:1.

## Content fundamentals

- Plain and exact. Say what will happen and how many ("Apply 525 changes"), not "Are you sure?".
- Sentence case everywhere; verbs on buttons ("Build plan", "Sync now", "Re-plan"). Rule names stay as the app defines them (BLOCK, WARN, I4).
- Numbers carry units and signs: currency code next to the amount, "+12.5%" and "−8.3%", never color alone.
- Errors say what is wrong and what to do next ("Enter at least 20 characters."). No exclamation marks, no emoji.
- Write to the user as "you" only when asking for a decision; otherwise describe the state ("12 cells are excluded").

## Iconography

Use SF Symbols in the app, in `accent` for navigation icons and the status color for badges. The component previews use a small set of inline stroke icons (check, triangle, octagon, circle-i, list, flag, clock, document) as stand-ins; replace with the matching SF Symbols (`checkmark`, `exclamationmark.triangle`, `xmark.octagon`, `info.circle`) when building. Icons are never the only carrier of meaning.

## Components

Ten components, all CSS-only in `bundle.css` with the `pu-` prefix: Button, GlassPanel, Badge, WorkspaceBanner, Field, SegmentedControl, DataTable, ConfirmSheet, ProgressBar, Sidebar. Each has a README with its SwiftUI counterpart. Wrap a screen in `pu-root` and, for previews and marketing, `pu-stage`.
