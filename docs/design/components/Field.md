# Field

A labeled text field with an optional hint, plus the checkbox, for settings and confirmation input.

**Use.** Every field has a visible label above it; placeholder text is only an example value. Use the monospace variant for IDs and hashes. Error text sits in the hint line in `danger`, with `aria-invalid="true"` on the input.

**Consumer provides.** A label, an input, optionally a hint and an error message.

**Rules.**
- The control outline is `border-control` (4:1 on its ground); the fill is `glass-fill`.
- Focus replaces nothing: `shadow-focus` is drawn around the control.
- Error text uses `danger` on `canvas` or glass; it never relies on red alone, so the message is always written out.
- Checkbox box is 14px, radius 4px, checked fill is `accent-fill` with an `on-accent` mark.
- In SwiftUI use `TextField` with `.textFieldStyle(.roundedBorder)` and `Toggle` with `.toggleStyle(.checkbox)`.
