# DataTable

A dense, read-only table for catalog rows and plan diffs: left-aligned text, right-aligned monospaced figures, one row per cell of change.

**Use.** Catalog (175 territory rows) and the Plan diff (before → after, delta, flags). Rows are not edited in place; to change a value, change the source and re-plan. Blocking rows get `is-blocked` (a `danger-tint` background) and a BLOCK badge in the Flags column.

**Consumer provides.** Column headers in sentence case, cell text, figures as plain numbers in `td.num`, optional flag badges in the last column.

**Rules.**
- Figures use the `figure` style (monospace, tabular numerals) and are right-aligned so decimals line up.
- Deltas: `success` for increases, `warning` for decreases, `text-primary` for no change. A sign (+ or −) is always written, so color is not the only signal.
- Header is `glass-fill` with a blur and stays sticky; rows are separated by `separator`.
- Hover uses `glass-fill-hover`; selection uses `accent-tint` with `text-primary`.
- Never drop below 13px text or 8px vertical padding in a row.
- In SwiftUI use `Table` with `.tableStyle(.inset(alternatesRowBackgrounds: false))` and `.monospacedDigit()` on figure columns.
