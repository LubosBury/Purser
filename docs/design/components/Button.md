# Button

A control that performs one action: glass by default, a solid accent fill for the single main action of a screen.

**Use.** One `pu-btn--primary` per screen or sheet (Build plan, Apply). Everything else is the default glass button. `pu-btn--danger` is only for Abort and Zrušit-style actions that stop or discard work. `pu-btn--plain` is for low-emphasis text actions in toolbars and table rows. Labels are verbs in sentence case ("Apply changes", "Sync now").

**Consumer provides.** A `<button>` with class `pu-btn` plus a variant and size modifier, a text label, and optionally one inline icon before the label.

**Rules.**
- Min height 28px (regular), 22px (small) only in table rows and toolbars. Large (36px) is for the primary action of an empty state or sheet.
- Hover darkens the primary fill, never lightens it, so `on-accent` keeps 4.5:1.
- Focus is `shadow-focus`, always visible on keyboard focus.
- Disabled uses `text-disabled`; say why in nearby text (for example "Sync first").
- In SwiftUI use `.buttonStyle(.glassProminent)` for primary and `.buttonStyle(.glass)` for the rest on macOS 26; before that `.borderedProminent` and `.bordered`.
