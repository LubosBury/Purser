# SegmentedControl

A single-choice switch between two to five peer views or filters, styled as one glass capsule with a raised selected segment.

**Use.** Source tabs on New plan (Import, Intro, Promo, IAP) and filters such as "Flagged only". Not for navigation between screens; that is the sidebar.

**Consumer provides.** Short labels (one or two words) and which one is selected via `aria-selected`.

**Rules.**
- Unselected labels are `text-secondary`, selected is `text-primary` on `glass-fill-pressed`.
- Always keep keyboard focus visible (`shadow-focus`).
- In SwiftUI use `Picker` with `.pickerStyle(.segmented)`.
