# ProgressBar

A thin pill-shaped bar with a labeled count, showing how far an apply has progressed and why it stopped when it has.

**Use.** On the Plan screen during Apply, in the same place as the diff header. Running is `accent`; paused turns `warning`, and the label changes to the pause reason in words ("Paused: CRASH").

**Consumer provides.** A state word, done and total counts, and an estimated time or the reason for the pause.

**Rules.**
- Always show the numbers ("212 of 525"); the bar alone is not enough.
- Track is `glass-fill-pressed`; the fill is 3:1 or more against it.
- Use `role="progressbar"` with min, max, and current values.
- In SwiftUI use `ProgressView(value:total:)` with `.progressViewStyle(.linear)`.
