# Badge

A small pill that names the status of a rule result, plan, or item in a word, with a colored tint as reinforcement.

**Use.** `danger` for BLOCK and failures, `warning` for WARN, Paused, Stale, `success` for Verified, Done, Effective, `info` for in-progress states, and the neutral badge for Draft and other quiet states. One badge per fact; put counts in the label ("BLOCK 148").

**Consumer provides.** The status word and, for danger, warning and success, an icon from the set (octagon, triangle, check). The word is always present: color is never the only signal, and success and danger differ in icon shape as well as hue.

**Rules.**
- Text colors are `danger`, `warning`, `success`, `info` on their `-tint` backgrounds; each is 4.5:1 or more.
- Labels use the rule or state name as defined by the app (for example "BLOCK", "Paused: CRASH"), not paraphrases.
- In SwiftUI use a `Label` in a `Capsule` background with the tint color at 14 to 18 percent opacity.
