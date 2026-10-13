# Spike SA: Sign in with Apple in a sandboxed app

> Historical. Sign in with Apple was removed on 2026-10-12 (spec D2): a Developer ID provisioning profile does not support it. The owner is now a name entered on first launch. The record is kept as it was planned.

| Field | Value |
|---|---|
| Date (UTC) | |
| Done by | |
| Purser commit | output of `git rev-parse --short HEAD` |
| Build | Debug, signed by the team from `Config/Signing.local.xcconfig` (`make build-signed` or Run in Xcode); TestFlight only in M5 |
| macOS | output of `sw_vers -productVersion` |
| Apple ID | only "owner"; do not write the Apple user id itself here |

## Question

Does Sign in with Apple through `ASAuthorizationController` work in a sandboxed macOS app with the entitlement
`com.apple.developer.applesignin`, and does `ASAuthorizationAppleIDProvider.credentialState(forUserID:)` return the right
state at launch for the signed-in, revoked and offline cases? (spec §9 SA, D2)

## Procedure

1. `make build-signed`, then `open build/DerivedData/Build/Products/Debug/Purser\ Pricing.app`.
2. First launch: sign in with Apple, confirm the system sheet, confirm Touch ID.
3. Quit (⌘Q) and launch again.
4. Lock through the menu Purser → "Lock Purser" (⌃⌘L), unlock.
5. Quit and launch with a short inactivity limit: `open build/DerivedData/Build/Products/Debug/Purser\ Pricing.app --args -PurserInactivitySeconds 20`, after unlocking do not touch the mouse or keyboard for 40 s.
6. Turn Wi-Fi off, quit and launch again; then turn Wi-Fi on.
7. System Settings → Apple Account → Sign-In & Security → Sign in with Apple → Purser → "Stop Using Apple ID"; quit and launch Purser again; sign in again with the same Apple ID.
8. Another Apple ID: on this Mac only with a second macOS user account, which however does not share the Keychain; the logic is covered by `OwnerRegistryTests`. The step is skipped if no second account is available.

## Observations

| # | Step | Expectation | Actual |
|---|---|---|---|
| 2 | First sign-in | the Sign in with Apple system sheet, then Touch ID, then the workspace picker | |
| 3 | Restart | no sign-in, straight to Touch ID (state `authorized`), then the workspace picker | |
| 4 | Manual lock | the "Purser is locked" screen, "Unlock" asks for Touch ID | |
| 5 | Inactivity | the lock screen within ~35 s | |
| 6 | Offline start | either a message that the Apple ID state cannot be checked and offline mode, or the cached state (`authorized`); write down which happened | |
| 7 | Revocation | a message that the Apple ID sign-in is no longer valid and the sign-in screen; a new sign-in with the same Apple ID goes through | |
| 8 | Another Apple ID | a message that this Apple ID is not the owner | |

## Result

Not run; superseded by the removal of Sign in with Apple.

## Effect on the code

- `AppleConstants`: no change.
- Contracts: no change.
- Tests: `OwnerRegistryTests` (owner logic); the UI is verified by hand.

## Fixtures

None.

## Open points

- None.
