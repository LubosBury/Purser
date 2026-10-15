# Badge

A small pill that names the status of a rule result, plan, item or version in a word, with a colored tint as reinforcement.

**Use.** `danger` for BLOCK and failures, `warning` for WARN, Paused, Stale and Removed, `success` for Verified, Done, Effective and Live, `info` for in-progress states (In review) and changes (Changed, New), and the neutral badge for Draft and other quiet states. One badge per fact; put counts in the label ("BLOCK 148").

**Consumer provides.** The status word and, when the state needs it, an icon. danger, warning and success bring their own icons (octagon, triangle, check). A neutral or info badge that stands for a version or a text change gets an icon from the table, so states that share a tint still differ in shape:

| State | Kind | Icon (SF Symbol) |
|---|---|---|
| Live | success | `checkmark` (the kind's own) |
| Draft | neutral | `pencil` |
| In review | info | `clock` |
| Replaced | neutral | `archivebox` |
| Changed | info | `arrow.left.arrow.right` |
| New | info | `plus` |
| Removed | warning | `exclamationmark.triangle` (the kind's own) |

A new state gets its icon here before a view uses it. The word is always present: color is never the only signal, and success and danger differ in icon shape as well as hue.

**Rules.**
- Text colors are `danger`, `warning`, `success`, `info` on their `-tint` backgrounds; each is 4.5:1 or more.
- Labels use the rule or state name as defined by the app (for example "BLOCK", "Paused: CRASH", "Draft · version 2"), not paraphrases.
- In SwiftUI use `PurserBadge(text:kind:icon:)`: the word and the icon in a `Capsule` background with the tint color at 14 to 18 percent opacity. `icon` is optional; when given it replaces the kind's own icon.
