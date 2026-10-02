# DockKeeper — Behavior Specification

| | |
|---|---|
| **Status** | Draft for review |
| **Date** | 2026-07-22 |
| **Owner** | blamechris |
| **Scope** | v1.0 externally observable behavior |
| **Inputs** | [Technical design](technical-design.md) (Appendix B seed IDs), [Preferred-display spike](spikes/preferred-display-spike.md) (owner Decisions 1–3, 2026-07-22), kickoff package Phase-3 template |

Evidence labels: **CONFIRMED** (verified on-device / Apple docs / reproducible experiment) · **INFERRED** (reasoned from confirmed facts) · **PROPOSED** (a choice this document makes) · **UNKNOWN** (needs investigation).

This document describes externally observable behavior only; mechanisms live in the [technical design](technical-design.md). Risk IDs (R-xxx) refer to the [risk register](risk-register.md); ADRs to the [decision log](decision-log.md).

## Conventions

- **IDs are stable.** `DK-FR-xxx` functional, `DK-NFR-xxx` non-functional, `DK-PRIV-xxx` privacy. (`DK-UX-xxx` is reserved; no UX-only requirements exist yet.) Never renumber; retire with a strikethrough and a note.
- **Priority**: **P0** — v1.0 cannot ship without it. **P1** — planned for v1.0; may individually degrade or slip with owner sign-off. **P2** — post-v1.
- Scenarios use Given/When/Then. Scenario IDs (`-S1` …) are referenced from [test-strategy.md](test-strategy.md).

### Requirements index

| ID | Title | Priority | Target |
|---|---|---|---|
| [DK-FR-001](#dk-fr-001-edge-lock-and-restore) | Edge lock and restore | P0 | v1.0 |
| [DK-FR-002](#dk-fr-002-preferred-display-pinning-best-effort) | Preferred-display pinning (best-effort) | P1 | v1.0 |
| [DK-FR-003](#dk-fr-003-recovery-after-system-events) | Recovery after system events | P0 | v1.0 |
| [DK-FR-004](#dk-fr-004-enable--disable) | Enable / disable | P0 | v1.0 |
| [DK-FR-005](#dk-fr-005-launch-at-login) | Launch at Login | P1 | v1.0 |
| [DK-FR-006](#dk-fr-006-menu-bar-controls-and-preferences) | Menu-bar controls and Preferences | P0 | v1.0 |
| [DK-FR-007](#dk-fr-007-command-line-interface) | Command-line interface | P1 | v1.0 |
| [DK-FR-009](#dk-fr-009-pause-and-temporary-dock-move) | Pause and temporary Dock move | P2 | v1.1 |
| [DK-FR-010](#dk-fr-010-apple-shortcuts--url-scheme-automation) | Apple Shortcuts + URL-scheme automation | P2 | v1.1 |
| [DK-FR-011](#dk-fr-011-hide-the-dock-during-screen-capture) | Hide the Dock during screen capture | P2 | v1.1 |
| [DK-FR-012](#dk-fr-012-single-instance-guard) | Single-instance guard | P1 | v1.0 |
| [DK-FR-013](#dk-fr-013-restore-borrowed-dock-auto-hide-across-process-death) | Restore borrowed Dock auto-hide across process death | P1 | v1.1 |
| [DK-FR-014](#dk-fr-014-hold-a-bottom-dock-on-the-preferred-display-separate-spaces-mode) | Hold a bottom Dock on the preferred display (separate-Spaces mode) | P2 | v1.1 |
| [DK-FR-015](#dk-fr-015-ask-a-running-instance-what-it-is-holding) | Ask a running instance what it is holding | P1 | v1.0 |
| [DK-NFR-001](#dk-nfr-001-quietness-and-resource-budget) | Quietness and resource budget | P0 | v1.0 |
| [DK-NFR-002](#dk-nfr-002-zero-network-communication) | Zero network communication | P0 | v1.0 |
| [DK-PRIV-001](#dk-priv-001-no-telemetry-accounts-or-data-collection) | No telemetry, accounts, or data collection | P0 | v1.0 |

---

## DK-FR-001: Edge lock and restore

**Description.** DockKeeper keeps the Dock on the user-chosen edge (bottom, left, or right) and restores it whenever macOS or anything else moves it. This is the headline, always-reliable feature (spike TL;DR, owner Decision 3).

**Rationale.** macOS relocates the Dock after sleep/wake, display plug/unplug, and resolution/arrangement changes, and offers no built-in "keep the Dock here." CONFIRMED (problem statement, TDD §1).

**Preconditions.** DockKeeper enabled (`DK-FR-004`); a lock edge is configured (default: bottom). Primary path additionally requires the private `CoreDock` symbols to resolve at runtime (CONFIRMED working on-device); otherwise the fallback path applies (S3).

**Trigger.** Drift detected by any monitored event or the polling safety net (`DK-FR-003`).

**Expected result.**

```text
S1 — Restore on drift (primary path)
Given DockKeeper is enabled with lock edge = left
And the CoreDock symbols resolve
When the observed Dock orientation is not left
Then DockKeeper sets the Dock orientation to left via the live CoreDock call
And the Dock is not restarted and does not flicker          [CONFIRMED on-device]
And the correction is logged locally when verbose logging is on

S2 — Idempotence (no oscillation)
Given the Dock is already on the locked edge
When a reconcile pass runs (event or poll)
Then no set call is issued and nothing visible happens

S3 — Fallback when CoreDock is unavailable
Given the CoreDock symbols fail to resolve
When a restore is needed
Then DockKeeper writes com.apple.dock orientation and restarts the Dock
And the app enters the Degraded state, surfaced in the menu (2026-07-22)
    and in CLI status
And the Dock restart is visible (accepted cost of the fallback)

S4 — Top edge is never offered
Given any configuration surface (menu, Preferences, CLI)
Then the selectable edges are exactly bottom, left, right   [CONFIRMED — existing test]
```

**Failure behavior.** If both the live read and the defaults read fail, the orientation is treated as unknown drift and the desired edge is applied (applying is idempotent and safe — TDD §5.3, PROPOSED). Retry ladder applies (`DK-FR-003`); if exhausted, state → `Error` with the last error surfaced.

**User-visible behavior.** Primary path: instant, flicker-free edge change. Fallback: visible Dock restart plus a "running degraded" note in the menu and CLI `status`.

**Testability.** Decision logic unit-testable once the `DockAdapter` seam exists (v0.1 gap — TDD §4.3); model mapping already covered by `DockOrientationTests` (CONFIRMED). See [test-strategy.md](test-strategy.md).

**Priority / target.** P0 / v1.0. **Related risks:** R-004 (CoreDock fragility), R-005 (oscillation), R-011 (Dock-restart persistence UNKNOWN).

---

## DK-FR-002: Preferred-display pinning (best-effort)

**Description.** The user may choose a preferred display; DockKeeper makes that display the macOS *main* display via public `CGDisplayConfiguration` APIs, which is where the Dock lives (with separate Spaces off). Explicitly **best-effort** (owner Decisions 1–3): the menu bar moves with the Dock (accepted, documented), and pinning is declined with an explanation when it cannot work honestly.

**Rationale.** There is no API — public or private within accepted risk — to place the Dock on a display directly; relocating the main display is the only public route. CONFIRMED (spike).

**Preconditions.** Enabled; a preferred display is stored (fingerprint per ADR-004 — implemented 2026-07-23, with write-once migration from the v0.1 bare UUID); at least two displays connected; "Displays have separate Spaces" is OFF **or** the lock edge is left/right (ADR-009 — left/right Docks home to the main display even in separate-Spaces mode, hardware-confirmed). The one scenario below that does *not* require a stored preference is S2c, which is an advisory rather than a pin.

**Trigger.** Reconcile pass (event, poll, enable, or the user picking a display).

**Expected result.**

```text
S1 — Pin (happy path)
Given separate Spaces is OFF and the preferred display is connected and not main
When a reconcile pass runs
Then DockKeeper reconfigures display origins so the preferred display becomes main
And the menu bar moves to that display (documented consequence)
And the outcome is surfaced in the menu
[Mechanism CONFIRMED available; end-to-end behavior on real multi-monitor
 hardware INFERRED — R-002, the top open risk]

S2 — Separate Spaces ON with a BOTTOM Dock (macOS default setting)
Given "Displays have separate Spaces" is ON and the lock edge is bottom
When a pin would otherwise apply
Then DockKeeper declines (unsupportedSeparateSpaces) and explains the
    remedies (left/right edge, turn the setting off, or turn on DK-FR-014's
    guard). With that guard on it says so, what it does when active and
    where its details are, instead of offering it — never that the Dock is
    pinned or is being kept, because the decision is not proof the tap is
    filtering and the guard never observes where the Dock is. With DockKeeper
    itself off, the advisory is not shown                        [#79]
And edge locking continues to work         [Decision 2A, narrowed by ADR-009]

S2b — Separate Spaces ON with a LEFT/RIGHT Dock
Given "Displays have separate Spaces" is ON and the lock edge is left or right
When a reconcile pass runs
Then main-display relocation applies as in S1 when necessary
And a side Dock on an already-main target is checked against a fresh host observation
And a known different host reports dockOnOtherDisplay, with no reconfiguration loop
And missing/ambiguous observation or an edge transition reports dockPlacementUnverified
And no menu bar moves, since every display keeps its own
[Original stacked-rig success: ADR-009. Side-by-side counterexample: fork ADR-F001.]

S2c — Separate Spaces ON, BOTTOM Dock, and NO preferred display stored
Given "Displays have separate Spaces" is ON and the lock edge is bottom
And at least two displays are connected
And no preferred display has been chosen
When a reconcile pass runs
Then DockKeeper reports bottomDockFollowsPointer and explains that macOS
    hands a bottom Dock to whichever display the pointer summons it to,
    offering the same two remedies as S2
And the message reaches the menu — S2's explanation is unreachable here,
    because the decision short-circuits on "no preference" first     [#44]

S3 — Preferred display absent
Given the preferred display is not connected
Then no fallback display is ever pinned                     [TDD §7.4]
And state = PreferredDisplayMissing with a menu note
And the edge lock remains enforced on whatever display macOS uses

S4 — Preferred display returns
Given state is PreferredDisplayMissing
When the display reconnects (reconfiguration event)
Then the pin is re-applied per S1

S5 — Already main / single display
Given the preferred display is already main, or only one display is connected
Then the pass is a no-op; side edges on an already-main display additionally
    require host verification per S2b (single-display handling stays unchanged)
```

**Failure behavior.** A failed `CGDisplayConfiguration` transaction is cancelled cleanly, reported as a typed `.failed` outcome with user-facing copy (CONFIRMED — implemented); the cooldown budget (`DK-FR-003`-S4) prevents retry storms. Ambiguous identity (two indistinguishable candidates) never guesses — the user is asked to re-pick (implemented 2026-07-23, `ambiguousIdentity` outcome).

**User-visible behavior.** A pin visibly re-arranges displays — inherent, not a defect; honest copy explains "on macOS, the Dock lives on your main display." Two documented consequences of the coordinate re-base (owner-observed 2026-07-23): in Spaces-off mode the menu bar moves with it; in any mode, **windows whose coordinates land on the re-based displays can shift to the other screen** (identical to changing the primary display in System Settings). Pins are rare events, so the shuffle is per-topology-change, not ongoing. The window shuffle is now **mitigable** via the opt-in "Keep windows in place when pinning" toggle (Preferences ▸ Advanced): when enabled and macOS Accessibility is granted, DockKeeper moves each window back to its original display after a pin; off by default, and a silent no-op without the grant (ADR-010).

**Testability.** `MainDisplayPinner.decide` is pure; all six decision branches covered today (CONFIRMED — `DisplayPinnerTests`). Needed: echo suppression, re-pin-on-return, fingerprint matching (see test strategy).

**Priority / target.** P1 / v1.0 (best-effort by decision). **Related risks:** R-002, R-003 (display identity), R-005.

---

## DK-FR-003: Recovery after system events

**Description.** DockKeeper detects and corrects Dock drift after sleep/wake, display connect/disconnect, resolution and arrangement changes, Space changes, and session reactivation — event-driven, with a low-frequency polling safety net (ADR-005).

**Rationale.** These are exactly the moments macOS moves the Dock; recovery is the product. Event catalog: TDD §8.1.

**Preconditions.** Enabled. (`enabled` is the single switch per ADR-007; v0.1's separate `autoRecover` — which gated only the poll — is retired and removed with M4.)

**Trigger.** Any event in TDD §8.1, or a poll tick (default 30 s per ADR-005 — shipped 2026-07-22).

**Expected result.**

```text
S1 — Wake with slow displays
Given the Mac wakes and displays are not yet ready
When the first reconcile attempt finds the topology incomplete
Then the retry ladder re-attempts (0 s, +1.5 s, +4 s)        [PROPOSED §8.4]
And the Dock converges to the locked edge / pin without user action

S2 — Event-burst coalescing
Given a display reconfiguration fires several events within milliseconds
When they arrive inside the debounce window (~400 ms)
Then exactly one reconcile attempt runs                      [PROPOSED §8.3]

S3 — Echo suppression
Given DockKeeper itself just performed a pin (which emits a reconfiguration event)
When that event arrives within the echo window (~2 s)
Then it is swallowed and does not trigger another pass       [PROPOSED §8.3]

S4 — Oscillation guard
Given some external agent keeps moving the Dock back
When more than 6 corrections occur within 60 s
Then DockKeeper stops correcting, enters Error, and tells the user
    (never a silent infinite fight)                          [PROPOSED §8.4]

S5 — Poll safety net
Given an event was missed (gap, unobserved cause)
When the poll tick finds drift
Then the drift is corrected and the poll-caught occurrence is counted locally
    (evidence for tuning the interval — ADR-005)
```

**Failure behavior.** Ladder exhausted → `Error`; recovery resumes on the next event or manual retry. Registration failure of any observer is covered by the poll.

**User-visible behavior.** None when healthy — recovery must be invisible (no oscillation). `Error` state surfaces the last error in the menu.

**Testability.** Pure `RecoveryMachine` core with synthetic event sequences and a simulated clock — **implemented and unit-tested 2026-07-22** ([RecoveryTests.swift](../Tests/DockKeeperTests/RecoveryTests.swift) covers S1–S5).

**Priority / target.** P0 / v1.0. **Related risks:** R-005, R-006, R-011.

---

## DK-FR-004: Enable / disable

**Description.** The user can disable DockKeeper at any time; disabled means DockKeeper touches nothing and consumes nothing.

**Rationale.** Kickoff principle: the app must be trustworthy and predictable; rule 20 (reliability before power features).

**Preconditions.** None.

**Trigger.** Menu toggle, Preferences, or `dockkeeper unlock` / settings edit via CLI.

**Expected result.**

```text
S1 — Disable is total
Given DockKeeper is enabled and monitoring
When the user disables it
Then all observers and timers are torn down
And no further corrections occur (zero footprint)
And the current Dock position and display arrangement are left exactly
    as-is (no snapshot-restore — ADR-006; the UI copy states this)

S2 — Enable reconciles
Given DockKeeper is disabled
When the user enables it
Then a full reconcile (edge + pin) runs after the settle delay
And the state machine proceeds Disabled → Starting → Monitoring
```

**Failure behavior.** None specific; enable failures surface as `DK-FR-001`/`DK-FR-002` outcomes.

**User-visible behavior.** Menu toggle state; icon should distinguish enabled/disabled (v0.1 uses one symbol — known debt, TDD A.4).

**Testability.** "Disable tears down observers/timers with no residual corrections" — needed test (Appendix B). Settings persistence covered (CONFIRMED — `SettingsTests`).

**Priority / target.** P0 / v1.0. **Related risks:** — .

---

## DK-FR-005: Launch at Login

**Description.** Optional launch-at-login via `SMAppService.mainApp`, with the system as the source of truth.

**Rationale.** A recovery utility only helps if it is running when the drift happens.

**Preconditions.** Running from a packaged `.app` bundle (CONFIRMED: `SMAppService` reports `.notFound` under `swift run`; documented in-code and in README).

**Trigger.** Toggle in Preferences / menu.

**Expected result.**

```text
S1 — Register / unregister
Given the app runs from a bundle
When the user toggles Launch at Login
Then SMAppService registers/unregisters the login item
And the UI reflects SMAppService.status, never a cached flag

S2 — Approval required
Given macOS reports .requiresApproval
Then the app explains why, and deep-links the user to the
    System Settings ▸ Login Items pane                       [CONFIRMED built]
And changes nothing on the user's behalf

S3 — Not packaged
Given the app runs via swift run
Then the toggle reverts and the UI explains that a packaged .app is required
```

**Failure behavior.** Registration throws → toggle reverts to system truth plus guidance (CONFIRMED built).

**User-visible behavior.** Toggle plus contextual guidance; a System Settings approval dialog may appear (system-owned).

**Testability.** `LoginItemManager.message(for:)` mapping unit-testable; approval flow is manual-matrix only (`SMAppService` untestable in unit scope — Appendix B).

**Priority / target.** P1 / v1.0. **Related risks:** — .

---

## DK-FR-006: Menu-bar controls and Preferences

**Description.** DockKeeper is a menu-bar accessory app (no Dock icon): a dropdown with the enable toggle, edge picker, display picker, status notes, and access to a Preferences window.

**Rationale.** The only always-available control surface; kickoff v1 boundary.

**Preconditions.** App running. `LSUIElement = true` in the bundle plist (CONFIRMED — `Resources/Info.plist`, packaged by `Scripts/build-app.sh`).

**Trigger.** User interaction.

**Expected result.**

```text
S1 — Accessory presentation
Given the app is running
Then no Dock icon or app switcher entry appears (accessory activation policy)
And a menu-bar item is present

S1b — Native selection marks (fork)
Given the user selects a Lock Edge or Preferred Display item
Then that choice displays the native macOS menu checkmark
And the other choices in the same submenu are unchecked
And clicking an already-selected item keeps that selection
And "Any (don't pin)" is checked only when no display preference is stored
And a disconnected stored preference is not misrepresented as "Any"

S2 — Honest status
Given the app is Degraded, or the preferred display is missing
Then the dropdown states it in plain language
[preferred-display copy exists in v0.1; the Degraded menu note is planned —
 today only CLI status reports it]

S3 — State-distinct icon
Given the app is enabled / disabled / degraded / paused
Then the menu-bar icon is visually distinct per state
[Implemented 2026-07-23 — RecoveryState.menuSymbolName, unit-pinned]
```

**Failure behavior.** n/a (UI surface).

**User-visible behavior.** As above. The unused `showMenuBarIcon` setting must be wired or removed before v1 (TDD §11 — a menu-bar-less mode without it is a trap).

**Testability.** Mostly manual; state-to-copy mappings unit-testable where pure.

**Priority / target.** P0 / v1.0. **Related risks:** R-009 (MenuBarExtra memory).

---

## DK-FR-007: Command-line interface

**Description.** `dockkeeper lock <edge> | unlock | status`, sharing `DockKeeperCore` and the same `UserDefaults`-backed settings as the app.

**Rationale.** Shipped early (kickoff deferred it post-v1 — harmless, keep; TDD A.3). Useful for scripting and headless fixes.

**Preconditions.** Same-user session. Both processes open the **explicitly named** `com.dockkeeper.app` suite (`Settings.suiteName`) — *not* `UserDefaults.standard`, which resolves by bundle identifier for the app but by process name for an unbundled executable. v0.9.0 shipped on `.standard`, so the CLI wrote to its own `dockkeeper`/`dockkeeper-cli` domain and `dockkeeper unlock` never reached the running app (CONFIRMED by the two separate plists on disk; fixed 2026-07-25, regression-tested by the shared-domain assertion in `ControlCommandTests`). The build product is `dockkeeper-cli` to avoid the case-insensitive product-name collision with the app (CONFIRMED — git history).

**Trigger.** User invocation.

**Expected result.**

```text
S1 — Lock / unlock
When the user runs `dockkeeper lock left`
Then the desired edge is persisted and applied immediately

S2 — Status is honest
When the user runs `dockkeeper status`
Then output includes current/desired edge, enablement, and Degraded state
                                                              [CONFIRMED built]

S3 — Running app follows CLI edits
Given the menu-bar app is running
When settings change via the CLI
Then the app's published state refreshes and reconciles if needed
[Implemented 2026-07-22 — KVO on the shared defaults sees cross-process
 edits; the menu updates live]
```

**Failure behavior.** Unknown arguments → usage text, non-zero exit. CoreDock unavailable in a non-AppKit process → explicit `dlopen` of HIServices hardening (PROPOSED, spike-validated).

**User-visible behavior.** Terminal output only.

**Testability.** Argument-parsing table test; `status` output snapshot (Appendix B — none exist yet).

**Priority / target.** P1 / v1.0. **Related risks:** R-004.

---

## DK-FR-009: Pause and temporary Dock move

**Description.** The user can temporarily suspend enforcement — "Pause for 15 Minutes", "Pause for 1 Hour", or "Pause Until Resumed" — and resume it ("Resume Now") from the menu or an optional global hotkey. While paused DockKeeper corrects nothing; on resume (manual or timed) a full reconcile re-enforces the locked edge and pin. This is the **temporary-move** story: pause → drag the Dock wherever via normal macOS → resume → DockKeeper re-enforces. (INFERRED framing; PROPOSED affordance. `DK-FR-008` is intentionally unused — the next stable ID after `DK-FR-007`; pause takes `DK-FR-009` to leave room.)

**Rationale.** Kickoff rule 20 (predictability first): enforcement that cannot be stepped out of is hostile when the user deliberately wants the Dock elsewhere for a while. Closes parity gap **G4** ([parity assessment](parity-assessment.md)) — DockLock's temporary-move/hotkey affordance — with a **zero-permission** mechanism (Carbon `RegisterEventHotKey` is public; TDD §10). The state machine already reserved `Paused` (TDD §5.1); this makes it reachable (CONFIRMED — `RecoveryState.paused`, `shouldProcess`/`reconcile` already gate on it).

**Preconditions.** DockKeeper enabled (`DK-FR-004`) — pause is meaningless while disabled and is rejected there (CONFIRMED — coordinator and machine both guard). The hotkey is off by default and, when on, is registered app-wide regardless of enabled state (a press while disabled is a safe no-op).

**Trigger.** Menu pause/resume items; or the optional ⌃⌥⌘D hotkey (Preferences ▸ Advanced), which toggles pause/resume through the same code path.

**Expected result.**

```text
S1 — Pause suspends and strands in-flight work
Given DockKeeper is enabled and monitoring
When the user pauses
Then any in-flight reconcile pass is stranded (generation bump)
And the state machine enters Paused (distinct menu-bar icon)
And no corrections occur until resume                        [PROPOSED §5.1]

S2 — Events during pause do nothing
Given DockKeeper is paused
When wake / display / poll events arrive
Then they are ignored (shouldProcess gates on Paused)        [CONFIRMED gate]
And the Dock may be moved freely via normal macOS
  — except a bottom Dock on a display guarded by DK-FR-014,
    which stays held: pause suspends corrections, and prevention
    has no correction to resume. See DK-FR-014 "not released
    while paused".

S3 — Timed pause auto-resumes and re-enforces
Given the user paused for 15 minutes or 1 hour
When the duration elapses
Then the injected scheduler auto-resumes                     [PROPOSED §9]
And a full reconcile re-enforces the locked edge / pin

S4 — Manual resume strands a pending auto-resume timer
Given a timed pause is in effect
When the user resumes manually first
Then a full reconcile runs immediately
And the pending auto-resume timer is stranded (pause-generation bump)

S5 — A second pause supersedes the first
Given a timed pause is in effect
When the user pauses again (any duration)
Then the first pause's auto-resume timer is stranded
And the new duration governs

S6 — A pause is observable from a process that is not holding it
Given DockKeeper is paused
When `dockkeeper status` or `DockKeeper --diagnostics` runs
Then the report says so, distinctly from Enabled                [ADR-014]
And `status` prints a Paused: line whether or not a pause is on
And --diagnostics prints a relative age, never a wall clock      [DK-PRIV-001 S2]

S7 — A restart is an implicit resume
Given DockKeeper is paused and the process dies (crash, kill, logout)
When DockKeeper next launches
Then the pause record is discarded, not honoured                 [ADR-014;
                                                                  CONFIRMED
                                                                  on-device
                                                                  2026-08-18,
                                                                  §3b row 4 —
                                                                  SIGKILL while
                                                                  paused, record
                                                                  survived the
                                                                  kill, relaunch
                                                                  removed the key]
And enforcement resumes normally

S8 — The record is read against a clock, not merely printed
Given a pause record whose pausedUntil has already passed
When `dockkeeper status` or the Siri/Shortcuts line runs
Then it reports the auto-resume as overdue, not as pending       [#47]
And it does not claim DockKeeper died — `status` reports
    configured state, not liveness                               [ADR-014]
And a deadline that is not on the reporting day carries its
    date, so a day-old record cannot read as later today
Given a pause record alongside Enabled: no
Then the voice line answers "disabled", dropping the pause
And `status` qualifies the Paused: line rather than suppressing
    it, so the report carries both facts without contradicting
    itself                                                       [#47]
```

**Failure behavior.** Hotkey registration failure (e.g. the combo is already claimed by another app) is logged and the feature stays off — no trap, no crash (CONFIRMED — `HotKeyCenter.start` returns on non-`noErr`). Resume always routes through the normal reconcile path, so post-resume drift inherits the `DK-FR-003` retry ladder and oscillation guard.

**User-visible behavior.** Menu shows the three pause items (hidden while disabled); while paused it shows "Paused" / "Paused until <time>" and "Resume Now". The menu-bar icon switches to `pause.rectangle` (CONFIRMED — `RecoveryState.menuSymbolName`). The menu is no longer the *only* observer (ADR-014, [#36](https://github.com/blamechris/DockKeeper/issues/36)): `dockkeeper status` prints a `Paused:` line always, `DockKeeper --diagnostics` prints one with a relative age, and the Siri/Shortcuts voice line leads with the pause **while enabled** rather than reporting "enabled" — which is true but the wrong answer while DockKeeper is deliberately correcting nothing. Since [#47](https://github.com/blamechris/DockKeeper/issues/47) the record is read against the reporting clock rather than printed verbatim: a deadline already passed reports as an overdue auto-resume instead of a pending one, a deadline on another day carries its date (`date: .omitted` alone rendered yesterday 3:45 PM identically to today's), and a record found alongside `Enabled: no` — reachable when an untrappable exit leaves it and a separate-process `dockkeeper unlock` then writes `isEnabled` — is qualified rather than suppressed, so the report stops contradicting itself without destroying the evidence. None of it is a liveness claim: `status` has no such signal and ADR-014 keeps it reporting configured state. Advanced-tab toggle "Global pause hotkey (⌃⌥⌘D)" with a caption naming the combo; off by default. No hotkey customization in v1.1 (future work).

**Testability.** Pure `RecoveryMachine` pause/resume transitions (incl. from-disabled rejection) and coordinator orchestration (strand-on-pause, ignore-events, auto-resume via fake scheduler, manual-resume strands stale timer, second-pause supersedes) are unit-tested with the existing simulated clock/scheduler harness ([RecoveryTests.swift](../Tests/DockKeeperTests/RecoveryTests.swift), S1–S5). S6's record half is unit-tested there too (`RecoveryCoordinator pause record`, `Settings.pauseRecord`, `StatusSummary pause reporting`): the record follows `machine.state` through every transition, writes once per change, and writes nothing across reconciles while unpaused. The **cross-process** half — a process reading a pause it does not host — is CONFIRMED by measurement (ADR-014 Evidence) rather than by unit test, because no unit test can establish it. S7 is INFERRED until §3b row 4 is run: the launch clear is a single guarded write in `AppState.init`, which the unit suite does not reach. **S8 is unit-tested** in the same suite (eleven cases, [#47](https://github.com/blamechris/DockKeeper/issues/47)), against a fixed clock supplied to `StatusSummary.reportedAt` rather than an ambient one — including the seam itself, that `live(settings:now:)` threads its injected clock through. The one part not covered there is the menu (`AppState.pausedStatusText`), which still renders `date: .omitted` unconditionally and is app-target code the test bundle cannot link ([#71](https://github.com/blamechris/DockKeeper/issues/71)). The Carbon hot-key wrapper and menu wiring are manual (system-level registration is out of unit scope).

**Priority / target.** P2 / v1.1. Justification: pure parity/convenience — not required to ship a trustworthy v1.0 (rule 20 favours it but does not gate on it), and it depends on no v1.0 work. Landed ahead of target as the cheapest parity win (zero permissions, reserved machinery). **Related risks:** R-005 (resume re-enters the reconcile machinery; the machine clears its oscillation budget on pause so a fresh fight is bounded again after resume).

---

## DK-FR-010: Apple Shortcuts + URL-scheme automation

**Description.** DockKeeper's existing controls are exposed to automation two ways: (a) a `dockkeeper://` URL scheme — `lock?edge=bottom|left|right`, `unlock`, `pause` (optional `?minutes=`), `resume` — and (b) App Intents (`LockDockIntent`, `UnlockDockIntent`, `PauseDockKeeperIntent`, `ResumeDockKeeperIntent`, `DockKeeperStatusIntent`) with an `AppShortcutsProvider` for Siri/Shortcuts phrases. Both paths route through **one** pure command layer (`ControlCommand`) and a single app-side funnel (`AppState.perform(_:)`) — the same enable/lock/pause/resume surface the menu and CLI already drive. Closes parity gap **G6** ([parity assessment](parity-assessment.md)). (INFERRED framing; PROPOSED affordance.)

**Rationale.** Kickoff §17 staged-parity: automation is a **DockLock Plus** premium differentiator (CONFIRMED — [product investigation](product-investigation.md)); exposing it needs no new engine mechanism and **no new permission** (App Intents and `CFBundleURLTypes` are public; the URL handler is a stock `NSApplicationDelegate` method). Makes **G7** (Raycast) a thin downstream deliverable over the same surface. No ADR — public APIs, no architectural deviation ([implementation plan](implementation-plan.md) M11).

**Preconditions.** For mutating commands the menu-bar app must be running so the shared `AppState` funnel exists; the URL scheme and App Intents `openAppWhenRun` launch it if needed (CONFIRMED — plumbing; launch/perform ordering for an accessory app is INFERRED, see Testability). `DockKeeperStatusIntent` reads the shared `Settings`/`DockController`/`CoreDock` directly (`StatusSummary.live()`), so it works whether or not the app is running (CONFIRMED — same surface the CLI uses).

**Trigger.** A `dockkeeper://…` URL opened by any app/script; or an intent run from Shortcuts, Siri, or the Shortcuts editor.

**Expected result.**

```text
S1 — URL parse table is total and safe
When a dockkeeper:// URL is opened
Then lock?edge=bottom|left|right → lock (edge case-insensitive)
And  unlock / resume → the matching command
And  pause → pause-until-resumed; pause?minutes=N → timed pause (N>0, capped 24h)
And  unknown scheme/host, top edge, or malformed minutes → the URL is ignored
                                                          [CONFIRMED — unit table]

S2 — Automation reuses the existing control surface
When a valid command executes
Then it funnels through AppState.perform(_:) — enable+lock, disable,
     pause(for:), or resume — with no new engine path       [CONFIRMED — code]
And  lock enables + sets the edge; unlock disables (CLI parity)

S3 — Status mirrors the CLI
When DockKeeperStatusIntent runs
Then it returns enabled / lock edge / current edge / mechanism, built from the
     same StatusSummary the `dockkeeper status` CLI prints  [CONFIRMED — shared type]

S4 — Privacy: URL logging is contents-free
When an invalid dockkeeper:// URL is opened
Then only the host and a validity flag are logged at debug level; query values
     (which could be anything) are never logged             [CONFIRMED — code]

S5 — Shortcuts/Siri discovery (runtime)
Given the App Intents + AppShortcutsProvider are compiled into the app
When the user opens Shortcuts or asks Siri
Then the intents and phrases are offered                    [INFERRED — see note]
```

**Failure behavior.** Unrecognized URLs are silently ignored (logged at debug, host only). A mutating intent whose `AppState` is not yet live is a safe no-op (no crash, no partial state). Malformed `minutes` never pauses. `unlock` while already disabled and `resume` while not paused are existing no-ops.

**User-visible behavior.** No new UI. Automation surfaces appear in Shortcuts/Siri and via the URL scheme; results are the same Dock/menu changes the manual controls produce. `DockKeeperStatusIntent` returns a short spoken/printed line.

**Testability.** The pure parse table (`ControlCommand.parse`) is exhaustively unit-tested — all four commands, edge case-insensitivity, top rejected, minutes present/absent/zero/negative/garbage/non-finite/over-cap, unknown hosts, foreign schemes, extra params ignored — plus `StatusSummary` line/format parity ([ControlCommandTests.swift](../Tests/DockKeeperTests/ControlCommandTests.swift), 19 tests). `ControlCommand` lives in `DockKeeperCore` (not the app target) precisely so the test target, which links only the core library, can import it; the side-effecting funnel stays in the app layer. **Manual / not-yet-executed (INFERRED, not CONFIRMED):** end-to-end Shortcuts/Siri invocation and URL-open dispatch on-device. **Known packaging gap (INFERRED):** App Intents metadata (`Metadata.appintents`) is normally emitted by an Xcode build phase; the current `swift build` + [build-app.sh](../Scripts/build-app.sh) path does not generate it, so Shortcuts/Siri *discovery* is UNKNOWN until packaging adds the extraction step. The intent/enum/provider code compiles under Swift 6 strict concurrency and is structurally correct; the URL scheme is the fully-working automation path in the interim.

**Priority / target.** P2 / v1.1. Justification: pure parity/convenience over public APIs; no permission, no new mechanism, and it unblocks G7. Landed as recommended order #2 after G4. **Related risks:** none new (no network, no permission, no persisted config beyond the existing `isEnabled`/`lockEdge`).

---

## DK-FR-011: Hide the Dock during screen capture

**Description.** When enabled (opt-in, **off by default**), DockKeeper turns on macOS Dock auto-hide while the screen is being captured/recorded/shared, so the Dock stays out of the capture, and restores it when the capture ends. It never disturbs a user who already runs auto-hide — and therefore never restores something it didn't change. Closes parity gap **G5** ([parity assessment](parity-assessment.md)). Governed by **[ADR-011](decision-log.md#adr-011-hide-the-dock-during-screen-capture-via-a-private-screen-watcher-flag--dock-auto-hide-opt-in)** (the interaction rules there are mandatory).

**Rationale.** DockLock Lite hides the Dock during screen sharing / meetings; this matches that behavior with a zero-permission mechanism. Screen-capture detection has **no public API** — the reliable signal is the private SkyLight `CGSIsScreenWatcherPresent` (the public camera-in-use signal detects a *video call*, a different trigger — spike [screen-share-hide](spikes/screen-share-hide.md)). Hiding reuses the already-CONFIRMED `CoreDockSetAutoHideEnabled`, so only the detector is new (ADR-011, the rule-7 sign-off).

**Preconditions.** DockKeeper enabled (`DK-FR-004`); the setting `hideDockDuringScreenShare` is on; and the private `CGSIsScreenWatcherPresent` symbol resolves on this macOS (`ScreenCapture.isAvailable`). When the symbol is absent the feature is inert and the Advanced-tab toggle is disabled with a note. No system permission is required.

**Trigger.** A dedicated 3 s poll (Principle 19: **no capture-state event source exists** — the private flag is poll-only; the poll runs only while the feature is on, DockKeeper is enabled, and the symbol resolved) reads `ScreenCapture.isCapturing()` and feeds `ScreenShareHider`.

**Expected result.**

```text
S1 — Hide on capture start (we own the change)
Given the feature is on, the symbol resolves, and the user's Dock auto-hide is OFF
When a screen capture begins (isCapturing() → true)
Then DockKeeper turns Dock auto-hide ON and records that it did so
And a FileDiagnostics "screenshare hidden" note is written (state only, no PII)
[decide() CONFIRMED by unit test; the true-capture flip is UNKNOWN pending
 on-device verification — ADR-011 Evidence, folded into M6/M12]

S2 — Restore on capture stop (only what we changed)
Given DockKeeper hid the Dock for a capture
When the capture ends (isCapturing() → false)
Then DockKeeper turns Dock auto-hide back OFF and clears its flag
And a FileDiagnostics "screenshare restored" note is written

S3 — Never fight a user who already auto-hides
Given the user's Dock auto-hide is already ON
When a capture starts and stops
Then DockKeeper does nothing — it never toggles auto-hide, and because it
    recorded no hide, it never "restores" (turns off) the user's setting
                                                        [CONFIRMED — decide table]

S4 — Idempotence
Given the capture state is unchanged across ticks
When the poll fires repeatedly
Then no auto-hide write is issued after the first transition   [CONFIRMED]

S5 — Off by default / unavailable
Given the setting is off (default), or the symbol is absent
Then the poll never runs and the Dock is never touched; the toggle is disabled
    with an explanatory note when the symbol is absent         [CONFIRMED]

S6 — Teardown never leaves the Dock hidden
Given DockKeeper hid the Dock
When the user turns the feature off, or disables DockKeeper
Then auto-hide is restored to OFF        [CONFIRMED — code, for the feature-off
    and app-disabled exits ONLY; every other exit — quit, SIGKILL, Force Quit,
    a crash, the logout kill — is DK-FR-013, not this scenario]
```

**Failure behavior.** Symbol absent → feature unavailable, toggle disabled, no-op (never a crash, no fallback needed — hiding the Dock is a comfort feature). A failed `CoreDockSetAutoHideEnabled` (private API gone at write time) leaves the flag unset so no phantom "restore" is attempted. The auto-hide toggle is a direct `CoreDock` call outside the recovery machinery, so it can never trigger a drift correction or oscillation (ADR-011 "Coordinator interaction", verified). **An untrappable death while a hide is held** — SIGKILL, Force Quit, a crash, the logout kill — is **not** covered here: the in-memory hide flag dies with the process, and the recovery is [DK-FR-013](#dk-fr-013-restore-borrowed-dock-auto-hide-across-process-death) (durable record + launch repair + a manual floor), added 2026-08-17 for issue #29.

**User-visible behavior.** The Dock auto-hides for the duration of a screen capture and returns afterward. Advanced-tab toggle "Hide the Dock while screen sharing" with a caption (off by default; explains the auto-hide-during-capture-and-restore behavior and that an existing auto-hide setting is left untouched); disabled with a "unavailable on this version of macOS" note when the symbol is absent.

**Testability.** The pure `ScreenShareHider.decide(capturing:weHidIt:currentAutoHide:)` is exhaustively unit-tested over all 8 input combinations — including the "user already auto-hides → never touch → never restore" cases, idempotence, and the setting-off short-circuit (registered default false) ([ScreenShareTests.swift](../Tests/DockKeeperTests/ScreenShareTests.swift)). The private-API reads/writes and the detector are **not** called from tests (would move the real Dock / need a real capture) — that is the on-device hardware cell (M6/M12). **UNKNOWN pending on-device verification:** does the watcher flag actually flip on a real capture, its latency, and which apps trip it (QuickTime, Zoom, Teams, Screen Sharing.app) — do **not** treat as CONFIRMED.

**Priority / target.** P2 / v1.1. Justification: pure parity/convenience (matches DockLock Lite's screen-sharing hide); not required to ship a trustworthy v1.0, zero-permission, and independent of v1.0 work. Uses a private API behind graceful degradation (ADR-011), like the CoreDock edge path. **Related risks:** R-004 (private-API fragility — adds the screen-watcher symbol to the per-macOS smoke test).

---

## DK-FR-012: Single-instance guard

**Description.** At most one DockKeeper menu-bar app runs per user session. A launch that finds an older DockKeeper already running exits immediately — before any engine, any Dock write, and any status item exists — leaving the running instance untouched. There is no alert and no window; the reason is written to stderr and to the unified log, and `--diagnostics` names every other live copy. Governed by **[ADR-012](decision-log.md#adr-012-single-instance-guard-in-process-at-appinit-lsmultipleinstancesprohibited-withheld)**.

**Rationale.** LaunchServices does *not* provide this for us: it keys its "already running?" test on the bundle's **inode identity**, not on its path or bundle identifier (CONFIRMED — the launchd job label is literally `application.com.dockkeeper.app.<bundle inode>.<exec inode>`, and a control bundle rebuilt at the same path launched a second process while an unchanged one only reopened). Two duplicate vectors follow (the dev-loop case measured; the end-user upgrade-in-place case INFERRED from the same inode rule): **two bundles at two paths** — a login item registered to `/Applications/DockKeeper.app` alongside a separately launched `dist/DockKeeper.app`. That this *configuration* was present on the owner's machine is CONFIRMED via `sfltool dumpbtm`; that it is what produced the two icons he saw is **UNKNOWN** — unified-log retention does not reach the sighting, and an enabled `pro.docklock.lite` login item is an unrefuted alternative explanation for one of the icons ([ADR-012](decision-log.md#adr-012-single-instance-guard-in-process-at-appinit-lsmultipleinstancesprohibited-withheld), "What is and is not established"). The requirement rests on the mechanism, which both vectors reach regardless. The second vector is **rebuild/upgrade-in-place** (any install that replaces the bundle changes its inode, so opening the new copy while the old one runs starts a second process — the dev loop hits this every iteration, and end users hit it dragging a new copy from the DMG over `/Applications`). Two instances mean two engines writing the Dock, and `LSUIElement` removes every affordance the user would use to notice or fix it: no Dock tile, no ⌘-Tab entry, no Force Quit row — only two identical menu-bar icons, with "Quit DockKeeper" ending one of them.

**Preconditions.** The process is **bundled** (`Bundle.main.bundleIdentifier != nil`). The check is **per uid**, because `InstanceGuard.decide` yields only to a peer satisfying `InstancePeer.sameSession(as: selfUID)` (CONFIRMED — unit-tested; removing that conjunct fails 6 cases). It deliberately does **not** rest on `NSRunningApplication` being session-scoped: Apple documents no scoping for that API and DTS calls the multi-GUI-session case undefined, which is why [ADR-012's 2026-08-18 amendment](decision-log.md#adr-012-single-instance-guard-in-process-at-appinit-lsmultipleinstancesprohibited-withheld) replaced that inference with a filter. Do not remove the uid conjunct as redundant. No setting gates it and no permission is required. `DOCKKEEPER_ALLOW_MULTIPLE_INSTANCES=1` in the environment stands it down entirely.

**Trigger.** Every app launch, from `DockKeeperApp.init()` — after one-shot CLI flags are handled and before the `AppState` autoclosure is evaluated.

**Expected result.**

```text
S1 — A second copy at a second path stands down
Given DockKeeper is running from /Applications/DockKeeper.app
When ~/Projects/DockKeeper/dist/DockKeeper.app is launched
Then the new process exits before starting its engine or status item
And exactly one menu-bar icon remains, the original one   [decide() CONFIRMED —
                                                           unit test; the
                                                           assembled deflection
                                                           is UNKNOWN pending
                                                           manual test 5]

S2 — A rebuilt/upgraded bundle at the SAME path stands down
Given DockKeeper is running and the bundle is rebuilt or replaced in place
When the new bundle is opened (a new inode, so LaunchServices launches it)
Then the new process exits and the running one keeps the Dock
And Scripts/run-app.sh quits the previous dist/ build first, so the dev loop
    ends with exactly one process running the newly built binary
                                                          [decide() CONFIRMED —
                                                           unit test; the script
                                                           and the assembled
                                                           deflection are UNKNOWN
                                                           pending manual test 3]

S3 — Seniority, not version, decides
Given an older DockKeeper is running
When a newer build is launched
Then the NEWER build exits and the OLDER one survives     [by design — see
                                                           Failure behavior]

S4 — A direct exec of the inner binary is ordered like any other process
Given DockKeeper is running from a registered bundle
When DockKeeper.app/Contents/MacOS/DockKeeper is exec'd directly (the README
     support flow), which has no LaunchServices launch date for its whole
     lifetime — in its own view AND in every peer's view
Then it is still ranked by when it started, because the guard reads the kernel
     process start time when LaunchServices has no date
And the later of the two exits, in EITHER order: a direct exec started second
     yields to the registered instance, and a registered launch started second
     yields to a direct exec that was already running
                                                          [decide() CONFIRMED —
                                                           unit test, both
                                                           directions; UNKNOWN
                                                           pending manual tests
                                                           7 and 7b]

S5 — Support flows are never pre-empted
When DockKeeper --diagnostics runs while an instance is live
Then the report still prints, and its "Other instances:" line names the
     running copy and its bundle path                     [decide() CONFIRMED —
                                                           unit test of the
                                                           shared flag set; the
                                                           printed line is
                                                           CONFIRMED — code,
                                                           UNKNOWN end-to-end
                                                           pending manual test 6]

S6 — The escape hatch is exact opt-in
When DOCKKEEPER_ALLOW_MULTIPLE_INSTANCES=1 is set
Then the launch proceeds regardless of who is running
And any other value (including "0") leaves the guard active [CONFIRMED — unit test]

S7 — Unbundled builds are outside the guard
When `swift run DockKeeper` or a bare .build/debug binary runs
Then it is neither blocked nor detected, and runs alongside the .app
                                                          [by design — keeps the
                                                           debugger loop flag-free;
                                                           CONFIRMED on-device
                                                           2026-08-18, §3b row 9 —
                                                           both halves, the second
                                                           observed from a third
                                                           process during the
                                                           overlap. One cause:
                                                           an unbundled build
                                                           registers with a NULL
                                                           bundle identifier]

S8 — Simultaneous launches leave exactly one survivor
Given any group of instances that can see each other
When each independently decides
Then exactly one proceeds — never two, and never zero     [total order by
                                                           construction —
                                                           ADR-012; CONFIRMED
                                                           for 3-instance groups
                                                           by a 27-case sweep
                                                           over every start-time
                                                           shape]

S10 — Another logged-in user's instance is not a duplicate
Given DockKeeper is running in user A's session (fast user switching)
When user B launches DockKeeper in their own session
Then B's launch proceeds — each user has their own Dock and their own
     instance, because the guard yields only to a same-uid peer  [CONFIRMED — unit]
And `--diagnostics` in either session lists the other's copy
     marked `(another user)`                                     [ADR-012 amendment]

S9 — The CLI is unaffected
When `dockkeeper lock left` (or any CLI command) runs while the app runs
Then nothing is deflected — dockkeeper-cli is a legitimate separate process and
     the guard is scoped to the menu-bar app              [CONFIRMED — code]
```

**Failure behavior.** The deflected launch exits **`EXIT_SUCCESS`**, not a failure code: a login item that correctly deferred to the incumbent must not read as a failed launch. Nothing downstream can tell a deflection from a launch — `open` returns 0 either way — so the deflection is not observable through an exit status. Five honest limits, none of them papered over:

- **A pending `dockkeeper://` URL carried by a deflected launch is DROPPED, silently.** Recovering it is experimentally impossible at this point in startup — Apple Event dispatch is gated on `NSApplication.run()`, so a `kAEGetURL` handler plus a 2.1 s run-loop spin before `NSApplicationMain` caught nothing, twice (ADR-012 option 4). This needs the explicit `open -a <copy>.app dockkeeper://…` form; plain `open dockkeeper://…` and `open -b com.dockkeeper.app` are routed by LaunchServices to the running instance and spawn nothing. The four App Intents share this limit through the same mechanism — all declare `openAppWhenRun: true`, so an intent that opens a copy whose inode differs from the running process is deflected before it can dispatch. Consistent with DK-FR-010's existing stance that a mutating command with no live `AppState` is a safe no-op.
- **A DockKeeper that is alive but WEDGED still outranks every new launch.** An unresponsive process keeps a valid start time, so launches deflect to it silently, and `LSUIElement` leaves no Dock tile, no ⌘-Tab entry and no Force Quit row to kill it with — the app becomes unstartable from the GUI. Recovery is `pkill -9 -x DockKeeper` (plain `pkill` is not enough: ADR-013's termination handling ignores SIGTERM and dispatches the quit through the main queue, which is the thing that is wedged), or `DockKeeper --diagnostics` to get the pid from the `Other instances:` line. `DOCKKEEPER_ALLOW_MULTIPLE_INSTANCES=1` does **not** help here: it cannot be set for a Finder double-click or a login-item launch. Detecting unresponsiveness at `App.init()` is deliberately not attempted.
- **The guard yields to the most SENIOR instance, not the newest VERSION.** If v0.9.0 is running and v0.9.1 is launched, v0.9.1 exits and v0.9.0 keeps running. A launch that silently kills the app you were using would be a worse surprise; the answer is one canonical installed bundle, not a smarter guard.
- **An unbundled build (`swift run DockKeeper`) is neither blocked nor detected.** With no bundle identifier it is invisible to LaunchServices as a peer and skips the check as a caller, so it runs a full engine beside the `.app`. Deliberate, and the reason duplicates are unreachable *via LaunchServices* rather than impossible.
- **Detection is not atomic.** If a second launch queries LaunchServices before the first has registered, neither sees the other and both proceed. Only a kernel-level lock or a bootstrap name closes that window, and both were rejected for demonstrated brick-the-launch failure modes (ADR-012 option 3).

**User-visible behavior.** No new UI, no alert, no dialog — an `LSUIElement` agent has nothing to show, and a modal at launch would be worse than the silence. The visible effect is the absence of a second menu-bar icon. A user who launches a second copy sees nothing happen; a developer running the app from a terminal sees a stderr notice naming the running pid and its bundle path, and how to override it. `--diagnostics` gains an `Other instances:` line (`none`, or pid + bundle path for each, with ` (another user)` appended to any instance owned by a different uid) so a support report answers "do you have two?" without the user needing to know that `LSUIElement` apps hide from the app switcher and from Force Quit. The report is deliberately **broader than the guard** — it lists another user's instance, which the guard ignores — and the suffix is what stops that breadth misleading: every pid on this line is documented below as the recovery handle, and an unmarked foreign pid would send support after a process the user can neither see nor signal.

**Testability.** The whole decision is pure and lives in `DockKeeperCore` (`InstanceGuard.decide`), which the test target links, so it is exhaustively unit-tested: sole instance, self-in-peer-list, newcomer yields, junior ignored, bundle path is never consulted so both duplicate vectors reduce to one decision, pid wrap-around vs start time, a dateless newcomer yields, a dated process beats a dateless one regardless of pid, **a newcomer yields to an already-settled incumbent in either pid order** (the sequential-incumbency invariant the simultaneous sweep does not model), `--diagnostics` never pre-empted, exact-match escape hatch, and a 27-combination sweep asserting **exactly one survivor** across every start-time shape *within one session* (a two-element test cannot catch a cyclic comparator; three can). Session scoping (S10) adds 8 further cases — foreign senior ignored, own senior still yields, mixed peers pick the same-uid incumbent, unknown uid never yielded to, all-foreign proceeds, a third user is foreign too, root-owned is foreign, and a junior own-peer still loses — [InstanceGuardTests.swift](../Tests/DockKeeperTests/InstanceGuardTests.swift). The `NSRunningApplication` read, the `sysctl` start-time/uid lookup and the `exit()` are behind `SingleInstance` in the app target and are **not** unit-tested (the last of them ends the process). **Not yet run, and therefore not CONFIRMED:** the assembled guard against a real double launch — the eleven-row manual matrix in [test-strategy.md](test-strategy.md) is outstanding. Row 1 (a second user account under fast user switching) **no longer gates the shipped guard** — since the ADR-012 amendment that property is the unit-tested invariant above rather than an on-device inference — but it remains an end-to-end confirmation and still gates the `LSMultipleInstancesProhibited` follow-on.

**Priority / target.** P1 / v1.0. Justification: it is the inter-process enforcement of an invariant the design already assumes ([technical design](technical-design.md) §9, "exactly one owner of reconciliation state"), the failure it prevents is user-visible, self-inflicted by a normal upgrade, and unrecoverable through the app's own UI. **Related risks:** none new (no network, no permission, no persisted state; the guard reads process state and exits); see **R-012** (DockLock coexistence — ADR-012 records an orphaned enabled login item for a deleted DockLock Lite, and that entry is the unrefuted alternative explanation for one of the two icons that prompted this requirement).

---

## DK-FR-013: Restore borrowed Dock auto-hide across process death

**Description.** When DockKeeper has turned macOS Dock auto-hide on for a screen capture ([DK-FR-011](#dk-fr-011-hide-the-dock-during-screen-capture)) and the process then dies without restoring it — quit, SIGKILL, Force Quit, a crash, or the kill at logout — the next launch turns auto-hide back off and says so. A durable record written *before* the borrowing write is what makes that possible; a manual "turn it off" command is the floor beneath it, available even when no record exists. Governed by **[ADR-013](decision-log.md#adr-013-borrowed-system-state-is-persisted-before-the-borrowing-write-and-reconciled-at-launch-termination-hooks-are-an-optimization-not-the-mechanism)**, which also amends [ADR-011](decision-log.md#adr-011-hide-the-dock-during-screen-capture-via-a-private-screen-watcher-flag--dock-auto-hide-opt-in).

**Rationale.** DK-FR-011's `weHidIt` flag was in-memory only, so an untrappable death left Dock auto-hide **on** with nothing recording that DockKeeper put it there. On the next launch the flag reads false while auto-hide reads on, and `decide` — correctly, per ADR-011's "never touch a user who already auto-hides" rule — returns `none` from then on: the feature never fires again and there is **no in-app recovery** (GitHub issue [#29](https://github.com/blamechris/DockKeeper/issues/29)). The user *can* recover by turning auto-hide off in System Settings, but nothing tells them DockKeeper is the cause. A termination hook cannot fix this on its own: for background (`LSUIElement`) processes loginwindow sends the Quit Apple Event but does not wait for a reply before killing (INFERRED — Apple, *System Startup Programming Topics*; ADR-013 Evidence), and logout is the most common real exit path.

**Preconditions.** None for the automatic repair beyond a persisted record existing — it deliberately runs **before** the enable/feature gating, so a Dock left auto-hidden is repaired even when the user has since turned the feature, or DockKeeper itself, off. "Beyond a persisted record existing" is enforced, not merely described: with no record the repair returns before evaluating either private port, so DK-FR-011's opt-in guarantee — the screen-watcher and the auto-hide read are untouched unless the user opted in — survives this launch hook (asserted by `repairWithNoRecordTouchesNoPrivateAPI`). The Dock write requires the private `CoreDock` symbols to resolve (ADR-003); when they do not, the repair is inert and the record is preserved. No permission is required; the manual recovery (S11) needs no record at all.

**Trigger.** Three: a capture hide or restore (writes/clears the record); process launch (`AppState.init`, once, before any start/stop gating); and the user invoking the manual recovery from the menu or Preferences ▸ Advanced.

**Expected result.**

```text
S1 — A hide is recorded before it is taken
Given the feature is on and a capture starts with auto-hide OFF
Then a hide record is persisted BEFORE Dock auto-hide is turned ON
And a failed auto-hide write clears the record again      [CONFIRMED — unit test;
    the ordering is asserted from inside the injected Dock write, and CONFIRMED
    by mutation: reversing the two lines fails that assertion alone]

S2 — A restore clears the record after it lands
Given DockKeeper holds a hide
When it restores (capture stop, feature off, app disabled, or quit)
Then Dock auto-hide is set OFF first and only then is the record cleared
And a failed write keeps the record, so the claim outlives the failure
                                                          [CONFIRMED — unit test]

S3 — Trappable quit restores immediately
Given DockKeeper holds a hide
When the user quits from the menu, or the process receives SIGTERM/SIGINT
Then auto-hide is restored before the process exits       [CONFIRMED — unit test
    for the restore itself; that the hook fires in the real signed bundle is
    manual and INFERRED — test-strategy §3c]

S4 — Untrappable death leaves a repairable trace
Given DockKeeper holds a hide
When the process is SIGKILLed, force-quit, crashes, or is killed at logout
Then the persisted record survives and the next launch has enough to repair
                                                          [record durability
    across process death CONFIRMED — measured 25/25, spikes/termination-and-
    defaults-durability.md; across kernel panic or power loss UNKNOWN — ADR-013]

S5 — Repair on next launch (the headline case, issue #29)
Given a hide record no older than the 7-day attribution window
And Dock auto-hide currently reads ON, with no capture running
When DockKeeper launches
Then auto-hide is set back OFF, the record is dropped, and a one-line note is
    shown in the menu                                     [CONFIRMED — repair
                                                           table + ports test]

S6 — Repair adopts rather than un-hides during a live capture
Given a hide record and a capture still running, with the poll about to start
When DockKeeper launches
Then it takes ownership of the existing hide and issues NO Dock write
And the normal capture-stop restore puts auto-hide back    [CONFIRMED — the
    "no Dock write" property; that the far end sees no Dock is on-device]

S7 — Never restores an auto-hide it did not observe as ON
Given a hide record and auto-hide currently reading OFF, or unreadable
When DockKeeper launches
Then no Dock write is issued; an OFF reading drops the record, an unreadable
    one keeps it for a macOS where the symbol resolves     [CONFIRMED — 48-case
                                                            safety sweep]

S8 — Never takes away a setting the user has lived with
Given a hide record older than the 7-day attribution window
When DockKeeper launches with auto-hide ON
Then the record is dropped and auto-hide is left exactly as it is
                                                          [CONFIRMED]

S9 — Repair runs even when the feature, or DockKeeper, is off
Given a hide record and the user has since disabled the feature in frustration
When DockKeeper launches
Then the repair still runs, and restores rather than adopts   [CONFIRMED —
    repair table, for the rule (featureActive: false -> .restore); that the call
    site in AppState.init is ungated and runs before applyEnabledState() is
    code-inspection only, since the test target does not link the app target]

S10 — A crash between the two writes is never worse than the bug
Given the process dies between the record write and the auto-hide ON write
Then the next launch sees auto-hide OFF and discards the record, at no cost
                                                          [CONFIRMED]

S11 — Manual recovery needs no record
Given the Dock is auto-hiding and the feature is on
Then both the menu and Preferences ▸ Advanced offer "Turn Off Dock Auto-Hide",
    the Preferences one unconditionally while the CoreDock auto-hide symbols
    resolve (which is the gate that matches the write, not CoreDock.isAvailable)
When the user invokes either
Then Dock auto-hide is turned OFF and any record is cleared, regardless of
    age, provenance, or whether a record exists at all     [CONFIRMED — unit
    test; the menu item's visibility and wording are manual, §3c]
```

**Failure behavior.** `CoreDock` unavailable → the repair is inert (`none`) and the record is **preserved**, so a macOS on which the symbol resolves can still repair. An undecodable record is treated as absent, which is the safe answer in every branch. A record lost to a kernel panic, a power loss, a wiped preferences domain, or a downgrade is unrecoverable automatically — S11 is the recovery, and that is why it is unconditional. The repair is announced rather than silent (one menu line), because it mutates a global system preference the user did not just ask for. **Known interaction, not a regression:** invoking S11 while a capture is genuinely running with the feature on will re-hide within one poll (3 s) — that is DK-FR-011 working as designed, and turning the feature off is the exit from that loop, which restores on the way out (`featureOffRestoresEvenWhileCapturing`). **Known bound on the window:** the record is stamped at the hide and never refreshed, so a *single* capture that runs longer than 7 days and is then killed repairs to `discard`; the outcome is the pre-fix status quo plus S11, and re-stamping was declined against the DK-NFR-001 tick budget (ADR-013).

**Ambiguity that is not resolved, and is not claimed to be.** At launch, "nothing touched auto-hide since we died" is **not separable** from "the user turned it off and then deliberately on", "the user saw it on and decided they like it", or "a third party set it" — all present identically as *record present, auto-hide on, not capturing*. No intent signal exists (ADR-013, Consequences). The design therefore bounds exposure with one honest quantity, `now − hiddenAt`, which over-estimates it and so errs toward *not* restoring; inside 7 days it restores, and the cost asymmetry is why: a false restore is visible in seconds, announced, reversible in one checkbox, fires at most once per crash, and self-clears, while a false non-restore is the status quo bug. **Related risk:** R-014.

**User-visible behavior.** After a crash or a logout with a hide held, the Dock stops auto-hiding on the next launch and the menu carries one line — *"Restored your Dock after a screen share ended unexpectedly."* — superseded by the next real screen-share transition. A launch that *adopts* (S6) is announced too, with its disclosure deferred to the restore that eventually discharges it, so neither acting branch mutates the setting silently. The note sits **below** the recovery `statusMessage` in the menu: it is sticky, and a `Degraded` / `Not converging` message is the only health surface this app has. While the Dock is auto-hiding and the feature is on, the menu offers **Turn Off Dock Auto-Hide**; Preferences ▸ Advanced carries the same **Turn Off Dock Auto-Hide** permanently, with a caption explaining when to use it. `--diagnostics` gains a read-only `Screen-share:` line reporting whether a record is held and its **relative** age (state only, no wall-clock stamp — DK-PRIV-001 S2). Nothing else changes: no new prompt, no new permission, no new poll.

**Testability.** `ScreenShareHider.repair(record:currentAutoHide:capturing:featureActive:now:window:)` is pure and total, and is exhaustively unit-tested: a 10-row rule table (one row per branch plus both window boundaries), a **48-combination** sweep asserting the safety property *never `.restore` or `.adopt` without observing auto-hide ON*, one-step convergence, and the 7-day window as an asserted constant. The side-effecting half — write-ahead/write-behind ordering, the end-to-end "process 1 killed, process 2 repairs", `.adopt` issuing no Dock write, and the manual recovery with and without a record — is driven through the injected `probe`/`readAutoHide`/`writeAutoHide` ports against a recording fake Dock and an isolated `UserDefaults` suite ([ScreenShareTests.swift](../Tests/DockKeeperTests/ScreenShareTests.swift)). **No private API is called and the real Dock never moves.** `ScreenShareHider.decide`'s 8-row ADR-011 table is deliberately **unchanged** (CONFIRMED by diff) and must stay passing — that is the proof obligation for the ADR-011 contract. **Manual / on-device, therefore INFERRED rather than CONFIRMED** ([test-strategy.md](test-strategy.md) §3c): the hook actually firing in the signed bundle at menu-Quit and at logout; `kill -TERM` on the installed app restoring; a real capture → real hide → `kill -9` → relaunch cycle; the `.adopt` no-flash property as seen by the far end of a real share; the menu item's visibility and wording; the logout path specifically; and cross-user behavior (argued from per-user domains, not measured).

**Priority / target.** P1 / v1.1. Justification: this is a **correctness defect in shipped behavior**, not a feature — the affected user is left with an auto-hiding Dock, no explanation, and a feature that silently never fires again — so it outranks DK-FR-011's own P2 even though it is confined to that feature's blast radius. **Related risks:** R-014 (cross-launch repair restores an auto-hide the user set themselves), R-004 (the repair's Dock write is the same private-API path).

---

## DK-FR-014: Hold a bottom Dock on the preferred display (separate-Spaces mode)

**Requirement.** With "Displays have separate Spaces" ON and the lock edge set to **bottom**, DockKeeper may keep the Dock on the preferred display by **preventing the pointer summon** that would move it. Opt-in, off by default, Accessibility-gated, and refused over any span of a bottom edge that is also the route between two displays — leaving a display unguarded entirely when its whole edge is such a route ([ADR-015](decision-log.md#adr-015-hold-a-bottom-dock-by-blocking-the-summon-never-by-relocating-it), amended 2026-09-03 for #83).

**It never moves the Dock.** Relocation is not available to any userspace process and this requirement does not promise it. See ADR-015 Evidence for the falsified candidates.

**Priority / target.** P2 / v1.1. Justification: it closes the last DockLock capability gap (G1), but it is opt-in, permission-gated, and its end-to-end effect is unconfirmed — so it earns a place in the product without gating v1.0, exactly as ADR-008 scoped it. **Related risks:** **R-015** (the tap is continuous-cost and its end-to-end effect unobserved) and **R-008** (Accessibility behavior changes across macOS releases, reopened by this requirement).

```
S1 — Off by default
Given a fresh install
Then lockBottomDockToDisplay is false and no event tap exists  [CONFIRMED — unit test]

S2 — Only a bottom Dock is guarded
Given the lock edge is left or right
Then the guard stays idle                                      [CONFIRMED — unit test;
                                                                left/right home to the
                                                                main display, ADR-009]

S3 — Only in separate-Spaces mode, and only with two displays
Given "Displays have separate Spaces" is off, or one display is attached
Then the guard stays idle                                      [CONFIRMED — unit test]

S4 — Needs a preferred display that is attached
Given no preference is stored, or the preferred display is absent
Then the guard stays idle and says which                       [CONFIRMED — unit test]

S5 — Needs Accessibility, and never pretends otherwise
Given the feature is on but AXIsProcessTrusted() is false
Then the guard stays idle and reports "waiting for permission" [CONFIRMED — unit test]
And no prompt is raised except from the toggle the user just used

S6 — A shared bottom edge is refused span by span, not display by
     display
Given another display sits flush beneath part of a display we
    would guard
Then the spans of that edge with nothing beneath them are      [CONFIRMED — unit test]
    clamped, and the shared span is left open
Because the shared span is the route the pointer takes between
    the two screens, and clamping it would trap the cursor
And a display shared along its whole bottom edge yields no      [CONFIRMED — unit test;
    zone at all, and the guard stays idle when no guardable      that a blocked span
    display remains                                              also cannot host a
                                                                 summon is INFERRED,
                                                                 one observation]
And a display guarded over only part of its edge is reported    [CONFIRMED — unit test]
    as partly covered, never as fully guarded
And a neighbour whose frame OVERLAPS the bottom edge blocks     [CONFIRMED — unit test;
    it, exactly as a flush one does                              fixed 2026-09-03, #83
Because its own rectangle covers ground at or above that edge,   review — v0.9.3's flush
    so a band there would sit on the display beneath             test was symmetric and
                                                                 dropped such a
                                                                 neighbour entirely]
And a real pointer still crosses through the shared span with   [CONFIRMED 2026-09-03
    per-span zones armed                                         with a control on the
                                                                 stacked-with-overhang
                                                                 rig: shared columns
                                                                 unclamped and reaching
                                                                 the display below,
                                                                 both overhangs held
                                                                 10/10 at clampY = -3,
                                                                 released control put
                                                                 every overhang back —
                                                                 test-strategy §3d row 9,
                                                                 hardware matrix s4. The
                                                                 Dock-migration clause was
                                                                 closed the same day by a
                                                                 real-hand push with a
                                                                 control, row 9f]

S11 — A display mirroring the preferred one is never guarded
Given another display shows the same pixels as the preferred one
Then no band is drawn on it                                     [CONFIRMED — unit test]
Because that band would land on the only screen the user sees

S12 — A zone never acts beyond the display it names
Given a pointer location below a guarded display's own frame
Then it is not clamped                                          [CONFIRMED — unit test]
Because the gate authorising a zone proves only a local property

S7 — Only non-preferred displays are guarded
Given a preferred display and one other, both with free bottom edges
Then exactly the other display is clamped                      [CONFIRMED — unit test]

S8 — Horizontal travel is never restricted
Given the pointer is inside a guarded band
Then only its y is pulled back; x is untouched                 [CONFIRMED — unit test]

S9 — The guard dies with the process
Given DockKeeper is killed, crashes, or the user logs out
Then the tap stops filtering and the pointer moves normally    [INFERRED (strong) —
                                                                an event tap is
                                                                process-owned, so no
                                                                launch repair is
                                                                needed, unlike
                                                                DK-FR-013; argued,
                                                                not yet demonstrated
                                                                by a kill -9 run]

S10 — A disabled tap is re-armed, not silently dropped
Given macOS disables the tap for slowness or user input
Then DockKeeper re-enables it and counts the event             [INFERRED — the app
                                                                target has no
                                                                automated coverage]
```

**Failure behavior.** Every unmet precondition is a silent no-op with a stated reason in `--diagnostics` and under the Preferences toggle. A refused `CGEventTapCreate`, a revoked grant, or a system-disabled tap all end with normal pointer movement — the feature fails open, never closed, because a closed failure is a trapped cursor.

**Known cost.** A guarded display's own Dock summon becomes unreachable while the guard is active. That is the feature working as specified — CONFIRMED with a control (§3d row 1, session 3). **Bottom hot corners are no longer claimed as part of the cost.** This paragraph and the Preferences text used to say they become unreachable too; that is FALSIFIED on device (2026-09-04, [session 6](hardware-matrix-results.md)): the pointer is correctly clamped to `clampY = −3`, but macOS's hot-corner trigger region is taller than the 3 pt guard band, so a bottom hot corner **still fires** while the guard is active. Corrected by [#99](https://github.com/blamechris/DockKeeper/issues/99): the Preferences text no longer names the hot corners at all, rather than claiming they keep working, because that was measured on one corner of one rig. On a display guarded over only part of its bottom edge ([ADR-015](decision-log.md#adr-015-hold-a-bottom-dock-by-blocking-the-summon-never-by-relocating-it) amendment 2026-09-03), the cost is confined to the guarded spans: the shared strip keeps its hot corner and can still summon the Dock, which is the same reason it is left open — it is the route between the two screens.

**The guard is not released while DockKeeper is paused**, and that is deliberate rather than an oversight: pause suspends *corrections*, and this feature has no correction to re-enforce afterwards — releasing it would be the one pause in the product that resume cannot undo, because relocation is impossible (ADR-015). DK-FR-009 S2's "the Dock may be moved freely" therefore does not hold for a bottom Dock on a guarded display while this feature is on. Precedent: DK-FR-011 likewise keeps mutating the Dock while paused.

**Testability.** The decision, the geometry gate, the free-span sweep and the clamp are pure and unit-tested (`BottomDockGuardTests`, **65 cases across six suites**), including the safety property asserted directly as an invariant over whole arrangements — *no emitted band ever overlaps a display flush beneath it* — and a differential test holding the interval arithmetic to a predicate that has no intervals in it. **Mutation coverage is stated as the exact edit so each number is reproducible, and it lives in [ADR-015's Evidence section](decision-log.md#adr-015-hold-a-bottom-dock-by-blocking-the-summon-never-by-relocating-it) only.** It was duplicated here until 2026-09-03; #83 changed two of the six figures, and a table maintained in two places is a table that goes stale in one of them — the same defect class as #72's false claims and the CLAUDE.md rule against a second derivation. The `CGEventTap` adapter is **not** unit-tested — the app target has no coverage — but its end-to-end behavior against a real pointer is **CONFIRMED on-device with a control** (2026-09-02, [hardware matrix session 3](hardware-matrix-results.md)): with the tap armed a real pointer could not summon the Dock to the guarded display, and with the tap released the same push summoned it. Tap state was read from the unified log on both runs rather than assumed, because `--diagnostics` cannot observe a live tap ([#77](https://github.com/blamechris/DockKeeper/issues/77), [#78](https://github.com/blamechris/DockKeeper/issues/78)).

---

## DK-FR-015: Ask a running instance what it is holding

**Requirement.** A running DockKeeper publishes what it is actually holding — the settings it has in memory, the Accessibility grant it sees, the guard decision it last computed and the vitals of its live tap — into the shared `com.dockkeeper.app` domain, where any process may read it back. `dockkeeper status --live` and `--diagnostics` report that record and nothing else; neither supplies a value the running instance did not publish. Published unconditionally, with no toggle: [#78](https://github.com/blamechris/DockKeeper/issues/78) proposed gating it off by default, and a gated instrument is absent in exactly the two moments it is wanted — a release-checklist §6 gate and a support request (ADR-016).

**It is a belief, not a proof.** The record says what the running app *thinks*. It cannot say that the tap is really filtering events — only that the app armed one and that macOS still reports it enabled — and a reader must never present it as more. What it can do, and what nothing in the product could do before, is make the app's belief comparable with the disk. That comparison is the whole feature: both historical false verdicts were a divergence between the two halves, and no surface could see both at once.

**Liveness is a kernel fact, never a freshness heuristic.** A reader asks `sysctl(KERN_PROC_PID)` whether the writing pid is still there and whether its start time still matches to the whole microsecond; it consults no timestamp in the record to decide that. The stamps are reported to the user as freshness and are never evidence of life. An age threshold would need a tolerance, a tolerance is a guess, and a guess is how an instrument starts lying.

**Nothing in the report is re-derived.** `LiveGuardReport` is handed a reading, three plain disk values and a clock; it holds no `Settings`, no `DockController`, no `CoreDock`, no `DisplayManager` and no `BottomDockGuard.decide`. "Never silently fall back to re-derivation" is therefore not a property a reviewer must keep policing — there is nothing in scope to re-derive *from*. That is deliberately stronger than a test of the same property, because a test can be deleted and a missing dependency cannot be forgotten.

**Priority / target.** P1 / v1.0. Justification: DockKeeper behaves identically without it — it touches no Dock, no pointer and no permission — so it is not P0. But the two false verdicts it removes were produced by v1.0's own support surfaces: `--diagnostics` reported `guarding 1 display(s)` while the tap had never armed ([#77](https://github.com/blamechris/DockKeeper/issues/77)), and reported `off — not enabled in Preferences` while the tap was actively clamping the pointer to `y = -3` ([#78](https://github.com/blamechris/DockKeeper/issues/78)). Shipping without it means shipping a release checklist whose §6 gate is demonstrably capable of passing on a lie. **Related risks:** **R-016** (the record is the app's belief, and the app-side publish/retract wiring is the half still unverified on device), **R-015** (this is the first surface anywhere that can see a tap macOS has disabled) and **R-008** (it reports the Accessibility grant as the running app sees it — the only process that can answer that question).

```
S1 — A running instance publishes what it holds
Given DockKeeper is running
When the guard is applied — a settings change, a display change,
    an Accessibility re-check, or the poll tick
Then it writes its held settings, its Accessibility grant, its [CONFIRMED — unit test;
    guard decision and its tap vitals, stamped with its own     the app-side publish is
    kernel identity                                             INFERRED — see
And an unchanged state is not rewritten                         Testability]
And nothing is published when the process cannot read its own
    kernel identity

S2 — Liveness comes from the process table, never from a clock
Given a published record
When a reader asks whether the writer is still alive
Then it asks the kernel for that pid's start time and compares [CONFIRMED — unit test;
    whole microseconds, and consults no stamp in the record     CONFIRMED on-device
Because a freshness threshold needs a tolerance, and a          2026-09-03 on a record
    tolerance is where a wrong answer hides                     19 s old — a freshness
                                                                test would have called
                                                                it live]

S3 — A recycled pid is not the writer
Given the writing process has exited and its pid has been reused
Then the reading is "that pid now belongs to another process", [CONFIRMED — unit test;
    never "live"                                                one microsecond of
                                                                difference is enough]

S4 — No not-live verdict shows a single field of guard state
Given any reading other than live
Then no held setting, decision, zone or counter is printed,     [CONFIRMED — unit test
    and the block says so in as many words                      over every not-live
Because the report that started this printed guard state that   case, and by
    nobody was holding                                          construction: only
                                                                `.live` carries the
                                                                record]

S5 — An instance that has published nothing is not "no instance"
Given a DockKeeper is running but has published no record
Then the reader says an instance is running and has published  [CONFIRMED on-device
    no live state, and names its pid, version and bundle path   2026-09-03 against the
Because that is a different fact from "no DockKeeper", and an   shipped 0.9.4, which
    `NSRunningApplication` liveness test gets the other one     publishes nothing —
    wrong — it cannot see an unbundled instance at all          exit 3]

S6 — A surviving record is evidence of an untrappable death
Given DockKeeper removes its record on a clean quit
When a record is found whose writer is not running
Then the reader reports that it was killed rather than quit    [CONFIRMED on-device
Because the only routes that skip the retraction are a crash,   2026-09-03 — `kill -9`,
    Force Quit, `kill -9`, and the logout kill                  exit 4. That a clean
                                                                quit retracts is
                                                                CONFIRMED at the
                                                                Settings layer and
                                                                INFERRED in the app]

S7 — A divergence is named, and so is the side in force
Given the running app holds bottom-guard on and the disk says off
When either surface is asked
Then the disagreement is printed field by field, followed by   [CONFIRMED on-device
    "the running app's values are the ones in force" and the    2026-09-03 — the
    list of keys a `defaults write` actually reaches            motivating incident
Because knowing only that the two disagree leaves the reader    reproduced with a real
    unable to predict what the pointer will do                  `defaults write`,
                                                                exit 6]

S8 — The counters are unreadable when nothing is armed
Given no tap is armed
Then no clamp or re-enable count is published or printed       [CONFIRMED — unit test;
Because they reset when a tap arms and never when one is        unreachable by
    released, so a released tap still holds the last run's      construction, not by
    totals                                                      discipline]

S9 — A tap macOS has disabled is armed and not filtering
Given macOS disabled the tap for slowness or user input
Then the record carries `CGEvent.tapIsEnabled` and the reader  [CONFIRMED — unit test
    prints "NOT filtering", not merely "armed"                  on the rendering. That
Because `isActive` is `tap != nil` and nothing more             this state ever occurs
                                                                in the field is
                                                                UNKNOWN — nothing could
                                                                observe it before]

S10 — Another user's record is not this session's state
Given fast user switching, and a record published by a process
    running as another uid
Then the reading is "another user's DockKeeper", never live    [CONFIRMED — unit test;
Because that is a different app managing a different Dock       not reproduced on
                                                                device, which would
                                                                need a second account]

S11 — A newer schema fails closed
Given a record whose schema this reader does not know
Then it refuses the record, names both versions, and says to   [CONFIRMED — unit test]
    update the CLI — it never best-effort parses it

S12 — Nothing in the block is re-derived
Given no instance is running
Then the block reports that, and prints no configured state    [CONFIRMED by
Because `dockkeeper status` already answers the configured      construction — the
    question and has always printed `Enabled: yes` with         renderer holds nothing
    nothing running; blending the two is the instrument that    to re-derive from; unit
    lied                                                        test on the not-live
                                                                branches]

S13 — Published by default, and carrying no personal data beyond
      the bundle path
Given a fresh install
Then every instance publishes, with no toggle to forget to     [CONFIRMED — unit test
    turn on, and the record carries pid, start time, uid,       that the key is neither
    version, bundle path, three settings, the decision          registered nor
    geometry and the tap counters — and nothing else            externally observed;
And the bundle path never reaches `os.Logger`, and every age a  the field list is code
    reader prints is relative (DK-PRIV-001 S2), though the      inspection]
    stored record itself carries absolute stamps

S14 — Exit codes gate on live AND consistent
Given release-checklist §6 wants a gate, not a paragraph
Then `status --live` exits 0 only when an instance is live and [CONFIRMED — unit test;
    agrees with the disk; 3 no live state, 4 writer gone,       3, 0, 6 and 4 observed
    5 unreadable, 6 live but diverging                          on-device 2026-09-03]
Because a gate that passed on "live but contradicting the disk"
    would pass on the exact condition #78 was filed about

S15 — The record checks itself, so #77 is caught with the
      settings agreeing
Given the app decided to guard but its tap never armed — the
    shape of #77, in which every setting matches on both sides
Then the reading names the contradiction and the gate refuses  [CONFIRMED — unit test;
    it, even though nothing on disk disagrees                    CONFIRMED on-device
And a tap macOS has disabled, and a span count that differs      2026-09-03: `Divergence:
    from the decision's, are named the same way                  none` beside `Warning:
Because #77 was never a settings disagreement, so a report       the decision says
    that compared only settings would print "agrees" directly     guarding but no tap is
    beneath the wrong verdict                                     armed`, exit 6]
```

**Failure behavior.** Every failure resolves to a named verdict rather than a guess. An undecodable record reads as `unreadable` with the decoder's reason attached, never as "nothing published": the `pauseRecord` idiom degrades a broken value to `nil`, which is correct there — "not paused" is a true and safe reading — and is a lie here, because "no instance is publishing" and "an instance published something I could not read" are different claims. A record stamped in this machine's future is called out rather than rendered as `0s`, and an absurd-but-decodable stamp renders as unreadable rather than trapping the process. On the writing side an encoding failure retracts the previous record instead of leaving a description of a state that no longer exists, and a process that cannot read its own kernel identity publishes nothing at all — a record whose writer cannot be proved alive is the unverifiable artifact this requirement exists to replace. The CLI fails the same way: trailing arguments to `status` used to be discarded silently, so `dockkeeper status --liv` printed the configured-state block and exited 0 — a typo answering the question this requirement exists to stop answering. Every token is accounted for now (DK-FR-007).

**Known cost.** The record is written from the tail of `applyBottomDockGuard()` and never from the tap's own callback, because an encoder and a defaults write on the mouse-move path is precisely the latency macOS disables a tap for. The clamp and re-enable counters are therefore refreshed only at the reconcile cadence — up to `max(5, recoveryInterval)` seconds, 30 s by default — and can be that far behind. The cost is stated rather than hidden: the record carries `observedAt`, every reader prints its age, and a *visibly* stale count is worth more than a fresher one that could stop the guard working. Everything else in the record is a state change and is published as it happens. An unchanged state is rewritten in exactly one circumstance — **while a tap is armed** — and that exception is the price of `observedAt` meaning anything. Suppress every unchanged write and the field silently stops meaning "when this was last observed" and starts meaning "when it last changed", at which point a healthy idle instance and one whose run loop has wedged are byte-identical while the wedged one has had its tap disabled by macOS and is guarding nothing. Refreshing while armed costs one small write per reconcile in exactly the window where that difference can hurt someone; an idle instance — every install with the feature off, which is the default — settles into writing nothing at all (DK-NFR-001 — an unchanged rewrite spends the quietness budget to say nothing new).

**The record is a support artifact, and it is stored as text for that reason.** `defaults read com.dockkeeper.app liveGuardRecord` *is* the machine-readable form — JSON with sorted keys, so two support reports diff cleanly — unlike `pauseRecord` and `screenShareHideRecord`, which store `Data` and render as a hex blob no support reader can use. The key is deliberately absent from the registration domain, because absence is a real state rather than a missing default, and absent from `Settings.externallyObservedKeys`, because this app writes it and observing a self-written key would turn every publish into a `.settingsChanged` event and a full reconcile (ADR-011 and ADR-014 already record that argument for the two records above it).

**Testability.** The wire format, the classifier and the renderer are pure and unit-tested (`LiveGuardTests`, **57 cases across six suites**; the whole suite moves from 294 tests in 43 suites to 351 in 49), with the kernel injected into `LiveGuardReading.classify` so a dead writer, a recycled pid and a foreign uid are all reachable from `swift test` with no hardware, no running app and nothing to kill. **Mutation coverage is stated as the exact edit, and lives in ADR-016's Evidence section only** — not duplicated here, for the reason DK-FR-014's Testability records. The **reader half is CONFIRMED on-device** (2026-09-03, against the real `com.dockkeeper.app` domain and the real kernel, with the shipped 0.9.4 running as pid 28571 throughout, and a throwaway harness standing in for the writer so no second DockKeeper went near the Dock): an instance that publishes nothing, a live and agreeing instance, the motivating divergence reproduced by a real `defaults write`, and a `kill -9`ed writer read as gone on a 19-second-old record — exits 3, 0, 6 and 4. That last figure is the control that matters: a design inferring liveness from freshness would have called a 19-second-old record live. The **writer half inside the app is CONFIRMED on device** (2026-09-04, [session 6](hardware-matrix-results.md), closing [#96](https://github.com/blamechris/DockKeeper/issues/96)). The new build ran as the real menu-bar app, displacing 0.9.4: `AppState.publishLiveGuardState()` was seen firing from `applyBottomDockGuard()` on a real state change, **with the control that makes it a measurement** — 20 s of idle left `stateChangedAt` untouched (`unchanged for` climbed 6 s → 26 s) while a real change reset it to 3 s and `Guard:`/`Tap:` followed. `prepareForTermination()` retracted on a clean quit (exit 3), and a `kill -9` left the record behind to be read as *killed rather than quit* (exit 4) 619 ms after the pointer was confirmed free. The armed heartbeat refreshed `observedAt` on **four consecutive 30 s intervals** while `unchanged for` climbed monotonically across the whole window, which turns the `max(5, recoveryInterval)` freshness bound from an argued figure into a measured one.

---


## DK-NFR-001: Quietness and resource budget

**Description.** DockKeeper must be effectively free at idle and invisible when healthy.

**Rationale.** Kickoff §6.14 budgets; a background utility that costs noticeable CPU, memory, or visual churn is worse than the problem it fixes.

**Preconditions.** None (applies in every state). **Trigger.** Continuous constraint, verified at the M6 measurement gate.

**Requirements** (M6 gate; idle CPU and memory first measured 2026-09-04, both partial — see the rows):

| Metric | Target | Evidence status |
|---|---|---|
| Idle CPU | ~0% under stable conditions | **0.0018% of one core** over a 600 s window with the guard **released** ([session 6](hardware-matrix-results.md), 2026-09-04) — a CPU-time delta, not `ps -o %cpu`. The **armed** figure is still unmeasured and is the open 24 h soak (R-015) |
| Memory | < 30 MB preferred; < 50 MB acceptable | **22.9 MB `phys_footprint`** — inside the *preferred* budget ([session 6](hardware-matrix-results.md), 2026-09-04), flat across the window (−0.02 MB). First real reading; was UNKNOWN on the R-009 "commonly 25–50 MB" prior. **Growth over 24 h is still unmeasured** — 10 minutes cannot see a slow leak |
| Cold launch | < 1 s on supported hardware | INFERRED |
| Visible behavior | No Dock oscillation ever; no flicker on the primary edge path | Flicker-free CONFIRMED on-device; oscillation guard PROPOSED |

**Failure behavior.** Budget misses at M6 are release blockers or require an owner-ratified budget change.

**User-visible behavior.** None when healthy — invisibility *is* the requirement; a budget miss surfaces as fan noise, Activity Monitor presence, or visible Dock churn, all of which are failures.

**Testability.** 24 h idle measurement, launch timing, memory growth over repeated event storms ([test-strategy.md](test-strategy.md) reliability suite).

**Priority / target.** P0 / v1.0. **Related risks:** R-005, R-006, R-009.

---

## DK-NFR-002: Zero network communication

**Description.** DockKeeper performs no network communication during normal operation. The only outbound anything is the user-initiated "Support Development" link opening GitHub in the browser.

**Rationale.** Kickoff non-negotiables 9 and 14: no unnecessary network communication; fully useful offline.

**Preconditions.** None (applies in every state). **Trigger.** Continuous constraint on all code paths.

**Evidence.** CONFIRMED by construction — no networking code exists (TDD §3, code inspection).

**Expected result.**

```text
S1 — No requests
Given any normal operation (monitoring, restoring, preferences, CLI)
Then zero network requests are made

S2 — Donation link is passive
Given the user clicks "Support Development"
Then the system browser opens the GitHub page; nothing else fires
```

**Failure behavior.** Any regression is a release blocker.

**User-visible behavior.** None — the observable behavior is the absence of network activity (verifiable with a network monitor).

**Testability.** CI check that no networking symbols are referenced (PROPOSED, TDD §14); manual verification with a network monitor at release.

**Priority / target.** P0 / v1.0. **Related risks:** — .

---

## DK-PRIV-001: No telemetry, accounts, or data collection

**Description.** No telemetry, analytics, accounts, advertisements, or remote backend — ever. Diagnostics are local, opt-in, and bounded.

**Rationale.** Kickoff non-negotiables 1–9: the product's entire premise is a trustworthy free alternative; privacy is not a feature tier.

**Preconditions.** None (applies in every state). **Trigger.** Continuous constraint on all code paths and all stored data.

**Expected result.**

```text
S1 — Nothing leaves the machine
Then no usage data, identifiers, or logs are transmitted anywhere   [CONFIRMED
    by construction — no networking code]

S2 — Local logs are opt-in and bounded
Given verbose logging is off (default)
Then only default os_log lines exist (system-managed retention)
Given the diagnostics file is enabled (off by default)
Then it is bounded (~1 MB size-rotate with one predecessor, 7-day prune)
    and contains no sensitive names (state names, edge names, pin
    outcomes only)                        [Implemented 2026-07-23, unit-tested]

S3 — No prompts
Then no donation prompt, upgrade prompt, or nag ever interrupts use
    (the kickoff allows a passive link only; v0.1 exceeds this — no
    automatic prompt exists at all)                                 [CONFIRMED]
```

**Failure behavior.** Any violation is a release blocker; no exceptions.

**User-visible behavior.** None — the absence of prompts, accounts, and collection is the behavior.

**Testability.** Code inspection + the DK-NFR-002 CI check; log-content review at release.

**Priority / target.** P0 / v1.0. **Related risks:** — .

---

## State transitions

The authoritative state machine (diagram and semantics) is TDD §5.1. States: `Disabled`, `Starting`, `Monitoring`, `Restoring`, `PreferredDisplayMissing`, `Degraded`, `Paused` (planned), `Error`.

**Documented deviation from the kickoff template:** `Awaiting Permission` is not a top-level app state. Each of the two opt-in Accessibility features — window restore (ADR-010) and the bottom-Dock guard (ADR-015) — degrades in place with its own caption beside its own toggle, rather than putting the whole app into a waiting state; the app is fully functional without either (TDD §10 / §10a).

| Transition | Trigger | Requirement |
|---|---|---|
| Disabled → Starting → Monitoring | User enables; initial reconcile completes | DK-FR-004 S2 |
| Monitoring → Restoring → Monitoring | Drift/event; convergence | DK-FR-001 S1, DK-FR-003 |
| Restoring/Monitoring → PreferredDisplayMissing | Preferred display absent | DK-FR-002 S3 |
| PreferredDisplayMissing → Restoring | Display reconnects | DK-FR-002 S4 |
| Restoring → Degraded | CoreDock unavailable | DK-FR-001 S3 |
| Restoring → Error | Retry ladder exhausted / oscillation budget | DK-FR-003 S4 |
| Error → Monitoring | Next event or manual retry | DK-FR-003 |
| non-Disabled → Paused | User pauses (menu or hotkey) | DK-FR-009 S1 |
| Paused → Starting → Monitoring | Resume (manual or timed) → reconcile | DK-FR-009 S3/S4 |
| any → Disabled | User disables | DK-FR-004 S1 |
