# ConfirmSheet

A modal glass sheet that stops a risky write and asks for explicit confirmation, escalating with the risk of the change.

**Use.** Before every Apply. The sheet always opens with the workspace banner, then a plain-language title with the count of changes, a summary, then the confirmations the risk level requires: tick the excluded cells (all applies); type the app name (production workspaces); give a reason of 20 characters or more and tick each risk class (risky changes). The primary button stays disabled until every required step is done and then reads "Apply with Touch ID".

**Consumer provides.** Workspace banner data, change count, excluded count, the list of required confirmations, and the actions.

**Rules.**
- Sheet width max 440px, radius `radius-xl`, `shadow-sheet`, over `scrim`.
- The destructive action is the primary button only when it is the intended next step; Cancel is always the default glass button on its left.
- Disabled primary stays visible and says why through the unchecked items above it.
- Esc cancels. Return does not confirm when a checkbox or text step is open.
- In SwiftUI present with `.sheet` and `.presentationBackground(.regularMaterial)`; keep the banner as the first view.
