# GlassPanel

The base surface of the app: a translucent white fill over black, blurred, with a 1px top highlight that gives the glass its edge.

**Use.** Group related content on a screen (a summary, a policy panel, a form). Use the default panel for content in the window and `pu-glass--sheet` for anything that floats above it (sheets, popovers). Do not nest glass in glass; inside a panel use `separator` lines or `glass-fill` rows.

**Consumer provides.** Children, and a stage behind it. Glass needs something to blur: place it on `canvas` or on the `pu-stage` helper, never on `surface-3` or lighter.

**Rules.**
- Text on glass is `text-primary`, `text-secondary` or `text-tertiary` only; all three hold 4.5:1 up to `glass-fill-hover`.
- When the system asks to reduce transparency the panel becomes opaque `surface-2` (`surface-3` for sheets). Build both states.
- Padding is `space-4` (panel) or `space-5` (sheet); gap between panels is `space-4`.
- In SwiftUI use `.glassEffect(.regular, in: .rect(cornerRadius: 14))` inside a `GlassEffectContainer` on macOS 26, or `.background(.ultraThinMaterial)` before that, over a black window background.
