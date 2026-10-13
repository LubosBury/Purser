# Sidebar

The source list on the left of the window: glass, grouped under small labels, with the current screen marked by `accent-tint`.

**Use.** Switch between Catalog, Findings, New plan, History and Settings. At most about eight items; counts only where they mean "needs attention". The workspace banner sits above, spanning the full width of the window.

**Consumer provides.** Group labels, items with an icon and a text label, optional count, and which item is current via `aria-current="page"`.

**Rules.**
- Width 200px; item height about 26px; icon 15px in `accent`.
- Labels use `body`; group labels use `subheadline` in `text-tertiary`.
- In SwiftUI use `List` with `.listStyle(.sidebar)` inside `NavigationSplitView`; the system provides the material.
