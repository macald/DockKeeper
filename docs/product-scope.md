# DockKeeper — Product Scope

| | |
|---|---|
| **Status** | PROPOSED — distilled from the owner's Agent Kickoff Package (§1, §3, §17); the owner's original scope document was chat-only and is not in the repo. Owner may replace or ratify this distillation. |
| **Date** | 2026-07-23 |
| **Owner** | blamechris |

## What DockKeeper is

A **free, open-source, native macOS utility** that provides reliable Dock
placement management: keep the Dock on the edge (and, best-effort, the
display) you chose, and put it back automatically when macOS moves it —
after sleep/wake, display plug/unplug, and resolution or arrangement changes.

It is a respectful alternative to commercial Dock utilities (the DockLock
family — see [product-investigation.md](product-investigation.md)): no
subscriptions, no trial expiration, no feature gates, no telemetry, no
advertisements, no recurring donation prompts. Independent implementation
only — no proprietary code, assets, branding, or text from any other product.

## Non-negotiable principles

1. Free forever; every functional feature available without payment.
2. Donations optional (a passive link), never interrupting use.
3. No subscriptions, trials, accounts, or ads.
4. No telemetry or analytics; no unnecessary network communication; fully
   useful offline. (Shipped: zero networking code — see [PRIVACY.md](../PRIVACY.md).)
5. Native macOS implementation (SwiftUI/AppKit); no Electron/Tauri/web views.
6. Public, supported APIs strongly preferred; deviations need an owner-ratified
   ADR (ADR-003 is the one such deviation).
7. Permissions only when technically necessary, always explained. (Shipped:
   none required by default; two opt-in features — window restore (ADR-010)
   and the bottom-Dock guard (ADR-015) — ask for Accessibility, each explained
   before its one prompt. The fork adds a third, the side-Dock pointer bridge
   (ADR-F002), on the same terms.)
8. Codebase suitable for an MIT-licensed public repository.

## v1.0 boundary

**In:** enable/disable; lock the Dock to bottom/left/right; best-effort
preferred-display pinning (honestly declined when "Displays have separate
Spaces" is on); recovery after wake, display reconnect, and resolution or
arrangement changes; Launch at Login; menu-bar controls + Preferences; local
opt-in diagnostics; CLI (`dockkeeper lock/unlock/status`); optional donation
link; zero network.

**Out of v1.0 (deferred until core reliability is proven):** follow-mouse /
follow-focused-window / follow-active-app modes; Apple Shortcuts / Raycast /
AppleScript; display profiles and per-app rules; App Store distribution;
auto-update. **Pinning while "separate Spaces" is on** — the competitor's only
supported mode — is out of v1.0 but **in active development for v1.1**
(owner-directed full replacement, ADR-008; spike underway).

Detailed behavior lives in [behavior-specification.md](behavior-specification.md);
the delivery sequence in [implementation-plan.md](implementation-plan.md).
