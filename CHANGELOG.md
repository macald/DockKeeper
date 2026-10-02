# Changelog

All notable user-facing changes to DockKeeper, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). All 0.9.x releases are public betas (GitHub pre-releases).

## [Unreleased]

### Added (fork)

- **A side Dock can now stay on your preferred display even when macOS insists on the display beside it.** On some arrangements macOS will not put a Left or Right Dock on a display whose edge touches another screen, whichever display is main. Place the other display above or below your preferred one, sticking out past the Dock edge (System Settings › Displays › Arrange), and turn on *Let the pointer cross a side Dock's edge* in Preferences › Advanced: macOS keeps the Dock on your preferred display, and pushing the pointer past that edge crosses to the other display as if they were side by side, including window and file drags. Off by default; needs Accessibility; two displays only. Behaviour after sleep, reconnection and in full screen is not yet measured.

## [0.9.5] — 2026-09-26

Sixth public beta. It makes DockKeeper checkable: you can ask the copy running in your menu bar what it is actually holding. It also stops the app's own text contradicting the bottom-Dock guard.

### Added

- **You can now ask a running DockKeeper what it is actually doing.** `dockkeeper status --live` reports the state of the copy in your menu bar instead of inferring it: the settings it is holding in memory, whether *it* sees the Accessibility permission, whether the bottom-Dock guard's pointer tap is armed, and whether macOS currently has that tap filtering. When any of it disagrees with the settings on this Mac, the report names the disagreement and says which side is in force — the running app's. That case is not hypothetical: a `defaults write` to the bottom-guard setting never reaches a running app, so the guard can be holding your pointer while every other report says the feature is off. `dockkeeper status` on its own is unchanged — it reports your *configured* state and has never claimed to know whether DockKeeper is running — and the live block never quietly falls back to it: with nothing published it says so and prints no guard state at all, and it distinguishes "no DockKeeper is running" from "one is running but has published nothing". Whether the publisher is still alive is asked of the kernel rather than guessed from how recent the record is, so a record left behind by a `kill -9` reads as stale seconds later. Exit codes, for scripts and release gates: `0` live and agreeing with your settings, `3` nothing published, `4` the publisher is gone, `5` the record could not be read, `6` live but diverging. ([#78](https://github.com/blamechris/DockKeeper/issues/78))
- `--diagnostics` gained a `Live state:` row. Every other row in that report is re-derived from this Mac's settings by the process you just ran, which cannot see what a running app holds; this row is the only one that says whether the two agree. Twice a report has confidently contradicted the running app — once reporting the guard as guarding a display when its tap had never armed, once reporting it off while it was actively holding the pointer — and this row catches both.
- The record is published whenever DockKeeper is running, with nothing to switch on: a diagnostic you have to enable first is missing exactly when you need it. It lives in DockKeeper's own preferences, so `defaults read com.dockkeeper.app liveGuardRecord` is the same state in machine-readable form, and DockKeeper removes it when you quit — which is why a record that outlives its writer is itself evidence that DockKeeper was killed rather than quit. It names the running process, its version and install path, the settings it is holding and what the guard is doing; never pointer coordinates, window titles, or application names ([privacy statement](PRIVACY.md)).

### Fixed

- **The menu no longer ignores the bottom-Dock guard.** With "Displays have separate Spaces" on, the menu offered only the two old remedies — a left/right edge, or turning the macOS setting off — and said a bottom Dock can't be kept, even with the guard turned on. It now names the guard as a third option when it is off. When it is on, the menu says so and points at its details in Preferences, without claiming the Dock is being kept there. Either way it still says plainly that the guard cannot move a Dock back once macOS has moved it. With DockKeeper itself turned off, the advisory is no longer shown. ([#79](https://github.com/blamechris/DockKeeper/issues/79))
- **Preferences no longer says the bottom-Dock guard turns off your bottom hot corners.** On the one display measured, a guarded bottom corner still fired, so the text overstated what the feature costs. That clause is gone, rather than replaced with a promise the measurement cannot support. ([#99](https://github.com/blamechris/DockKeeper/issues/99))
- **`dockkeeper status` no longer ignores a mistyped option.** Trailing arguments were discarded silently, so `dockkeeper status --liv` printed the ordinary configured-state block and exited `0` — a confident answer to a question you did not ask, on the one command people run when they are already unsure what is happening. An unrecognised option is now an error.

### Known beta limits

- **The stacked-monitor Dock jump is not fixed by this release**, and has not been reproduced on a current build. Nothing in 0.9.5 targets it. If it happens with the guard on, run `--diagnostics` and `dockkeeper status --live` straight away and attach both to a new issue.
- The Preferences caption under the bottom-Dock guard can say "Active — holding…" from DockKeeper's plan even when the pointer tap is not actually running. `dockkeeper status --live` reports the tap's real state ([#105](https://github.com/blamechris/DockKeeper/issues/105)).
- 0.9.5 is published as a GitHub pre-release only. The Homebrew cask still installs 0.9.4.
- The live record's clamp and re-enable counters are refreshed on DockKeeper's regular re-check — every 30 seconds by default — and not on every pointer event. That is deliberate: doing extra work on the pointer path is how macOS decides an event tap is too slow and switches it off. So those two counts can lag by up to that interval. Every reading is printed with its age, so a stale one is visibly stale.

## [0.9.4] — 2026-09-03

Fifth public beta. One user-visible change, and it matters most on the arrangement it was found on: a screen stacked above another and sticking out past its sides.

### Changed

- **The bottom-Dock guard now covers the parts of an edge that overhang another screen**, instead of standing down over the whole display. If one of your screens sits above another and sticks out past its sides, only the *overlapping strip* is left open now — that strip is how your pointer travels between the two screens, so holding it would trap your cursor — and the overhangs, which have nothing beneath them, are guarded like any other free edge. On a 4K stacked above a MacBook that is about 2100 px of bottom edge that v0.9.3 left open. Preferences and `--diagnostics` now say "partly covered" for such a display rather than reporting it as fully guarded. ([#83](https://github.com/blamechris/DockKeeper/issues/83))

### Fixed

- **The bottom-Dock guard could hold the pointer on a strip belonging to the screen below it.** Deciding whether one screen sits beneath another compared the two edges by distance alone, so screens reported as *overlapping* by a point or two — which happens while macOS is rearranging displays — were treated as far apart rather than adjacent, and the guard held a band across ground the lower screen owned. Nobody reported hitting it; it was found by review. Present since the guard shipped in v0.9.3. ([#83](https://github.com/blamechris/DockKeeper/issues/83))

## [0.9.3] — 2026-09-02

Fourth public beta. The headline is a new opt-in feature: a bottom Dock can finally be kept on the display you chose.

### Added

- **A bottom Dock can now be kept on the display you chose.** With “Displays have separate Spaces” on, macOS hands a bottom Dock to whichever screen you push the pointer to — so it wanders. Turn on **Keep a bottom Dock on my preferred display** (Preferences › Advanced, off by default) and DockKeeper holds the pointer a few points clear of the bottom edge on your *other* displays, so the gesture that summons it there is not completed. It needs Accessibility permission, at least two displays, and a bottom-edge lock. It **does not move the Dock back** — macOS does not allow that, and DockKeeper will not pretend otherwise. A display with another screen directly beneath it is left unguarded: that bottom edge is how your pointer travels between the screens, and holding it would trap your cursor. The rest of your displays are still guarded — the feature only stands down entirely when that leaves nothing to guard. It also stands down while your displays are mirrored, since there is no second bottom edge to hold. While it is active, the bottom hot corners on the guarded displays stop working, and pausing DockKeeper does **not** release it — pause suspends corrections, and there is no correction here to resume. ([G1](docs/parity-assessment.md))

- `--diagnostics` gained a `Bottom guard:` line reporting whether the new guard is active and, when it is not, the specific precondition that is unmet — the support answer to “I turned it on and nothing happened”. It also names DockKeeper being switched off as its own reason, rather than reporting that as the feature being off.
- **You can now tell whether DockKeeper is paused without hunting for the menu-bar icon.** `dockkeeper status` gains a `Paused:` line — always present, so a paused install is distinguishable from a working one at a glance — and `DockKeeper --diagnostics` reports it too, which matters because a paused DockKeeper is *correctly* doing nothing and a support report from one used to look identical to a healthy install. Asking Siri or Shortcuts for the status now says the app is paused instead of just "enabled". Pausing does not survive a restart: relaunching DockKeeper resumes it. ([#36](https://github.com/blamechris/DockKeeper/issues/36))

### Fixed

- **A pause that has already expired no longer reads as though it were still running.** If DockKeeper was force-quit, killed, or logged out while paused, the note it leaves behind outlives it — and `dockkeeper status` printed that note as though the pause were still counting down, right down to a deadline that had already gone by. Worse, it showed only a time of day, so a pause left over from *yesterday* at 3:45 PM read as this afternoon. Status now says the auto-resume is overdue and gives the date when the deadline is not today. It still will not tell you whether DockKeeper is running — it has never been able to, and it does not now pretend to. Asking Siri or Shortcuts gives the same answer. ([#47](https://github.com/blamechris/DockKeeper/issues/47))
- **A disabled DockKeeper no longer says it is paused.** Turn DockKeeper off with `dockkeeper unlock` while a leftover pause note is sitting there and both the status output and the spoken answer insisted it was paused. Siri now answers that DockKeeper is disabled, and `status` keeps showing the leftover note but labels it, so the report stops contradicting itself without hiding anything. ([#47](https://github.com/blamechris/DockKeeper/issues/47))
- **The menu no longer cuts off the fix that actually works.** When a bottom Dock cannot be pinned because *Displays have separate Spaces* is on, DockKeeper explains why — but the explanation was one long sentence, and macOS truncates a long menu item through the middle. The half it removed was the part naming the remedy: move the Dock to the left or right edge. The message is now written so the remedy survives. ([#57](https://github.com/blamechris/DockKeeper/issues/57))
- **A Dock that jumps between monitors now explains itself instead of going quiet.** On a multi-display Mac with the macOS default “Displays have separate Spaces” turned on, macOS hands a *bottom* Dock to whichever display your pointer summons it to — DockKeeper cannot pin it there, and has always declined rather than fight the OS. But the explanation only ever appeared if you had already chosen a preferred display, which most people never do, so the common case was total silence and DockKeeper looked broken. It now tells you what macOS is doing and offers both fixes: lock the Dock to the left or right edge and pick a preferred display, or turn the setting off. ([#44](https://github.com/blamechris/DockKeeper/issues/44))
- **`--diagnostics` no longer says pinning is unsupported when it works.** With “Displays have separate Spaces” on, the report claimed pinning was unsupported outright. That is only true of a bottom Dock — a left or right Dock pins normally in that mode — so a support report could send you to the disruptive fix (turning the setting off, which needs a logout and moves the menu bar) when the easy one would have worked. It now reports the verdict for your actual lock edge. ([#45](https://github.com/blamechris/DockKeeper/issues/45))
- **Two people sharing a Mac each get their own DockKeeper.** If you use fast user switching, DockKeeper could mistake another logged-in user's copy for a duplicate of your own and quietly decline to start — and because it lives only in the menu bar, there was nothing to see and no error to report: it simply never appeared. It now recognises another user's copy as theirs, not a duplicate of yours. `DockKeeper --diagnostics` also labels those, so a support report cannot point you at a process belonging to someone else. ([#30](https://github.com/blamechris/DockKeeper/issues/30))
- **`DockKeeper --diagnostics` could crash instead of printing a report.** A malformed value in DockKeeper's saved settings would take the command down rather than being reported, which is the worst possible moment to lose it — it is the one command we ask people to run when something is wrong. It now says the record looks corrupt and carries on.
- **`--diagnostics` no longer opens with a warning that reads like a fault.** Every support report began with a system line saying an internal settings name *"does not make sense and will not work"* — alarming, and the first thing anyone sends us. Nothing was ever wrong: the app and the command-line tool deliberately share one settings store, and the app was reaching it by a route macOS grumbles about but honours. It now takes the route macOS expects, reads and writes exactly the same settings, and prints nothing extra. ([#34](https://github.com/blamechris/DockKeeper/issues/34))

### Known beta limits

- **The bottom-Dock guard's cost has not been measured.** It works: with it on, a real pointer cannot summon the Dock to a guarded display — confirmed on a two-display Mac, with the guard off as a control. What is not yet known is what it costs you. It watches pointer movement continuously while it is on, and that has never been measured over a long session. If your Mac feels warmer or slower with it on, turn it off and please tell us — the toggle is the off-switch and takes effect immediately.
- The bottom hot corners on guarded displays stop working while the guard is on. That is the mechanism, not a fault.
- The hardware matrix and the 24-hour idle soak are still outstanding; **v1.0.0 follows once both complete.**

## [0.9.2] — 2026-08-18

Third public beta. Two reliability fixes: one for the opt-in screen-share feature, one for running DockKeeper twice by accident.

### Upgrading from 0.9.1 — quit DockKeeper first

**Quit DockKeeper before you install this version.** Click the menu-bar icon, choose *Quit DockKeeper*, then install 0.9.2 and open it.

macOS treats a replaced app bundle as a brand-new application, so opening 0.9.2 while 0.9.1 is still running starts a *second* copy — and 0.9.2's new single-instance guard correctly refuses to be that second copy. It exits immediately and silently: no alert, no error, and because DockKeeper has no Dock icon, nothing at all to see. The copy still in your menu bar is the old one, and it stays that way until you quit it or restart the Mac.

If it has already happened, the fix is the same and takes two seconds: quit DockKeeper from the menu, then open it again. To check whether an old copy is still resident, run `/Applications/DockKeeper.app/Contents/MacOS/DockKeeper --diagnostics` and read the `Other instances:` line — it names the pid and bundle path of every other live copy. (`Version:` reports the bundle you just ran, not the copy in your menu bar.) `Other instances: none` means no DockKeeper is running at all, so the next copy you open takes charge.

### Fixed

- **Your Dock no longer stays hidden after an interrupted screen share.** With "hide the Dock while screen sharing" on, DockKeeper turns macOS Dock auto-hide on for the length of a capture and off again afterwards. If it was force-quit, crashed, or was killed at logout while a share was running, auto-hide was left on — and DockKeeper, which never touches auto-hide for people who set it themselves, read it as yours and never put it back. It now remembers that it borrowed the setting, restores it at the next launch (within 7 days of the share), and says so in the menu. Quitting DockKeeper normally puts the Dock back on the way out, so most of the time you never see the repair happen. ([#29](https://github.com/blamechris/DockKeeper/issues/29))
- **A second copy of DockKeeper no longer starts.** Two copies both correcting the Dock is the worst way to run it, and it was easy to reach: dragging a new copy over a running one without quitting first was enough, because macOS treats the replacement as a different app. A second launch now exits before it starts an engine or touches the Dock, and the copy already running stays in charge. There is no alert — nothing appears to happen, which is the point.

### Added

- **Turn Off Dock Auto-Hide** — in the menu while your Dock is auto-hiding and the screen-share feature is on, and always available in Preferences ▸ Advanced. Use it if your Dock is still hiding itself after a screen share ended badly. It works even when there is nothing for DockKeeper to remember: a Dock left that way by an older version, or a preferences file that did not survive.
- `--diagnostics` gained two lines — `Other instances:` names every other live copy and its path, and `Screen-share:` says whether a Dock hide is currently outstanding. A menu-bar-only app has no Force Quit row to check, so a support report is the only place to look.
- `DOCKKEEPER_ALLOW_MULTIPLE_INSTANCES=1` in the environment stands the single-instance guard down, for running two builds side by side from a terminal.
- README screenshots and badges, `SECURITY.md` (private vulnerability reporting), and contributor docs.

### Known beta limits

- The automatic Dock restore only fires within **7 days** of the interrupted share. Past that, DockKeeper assumes the setting is yours now and leaves it alone; **Turn Off Dock Auto-Hide** is the recovery, and it has no time limit.
- If a copy of DockKeeper is running but wedged, new launches now defer to it and appear to do nothing — and a menu-bar-only app has no Force Quit row. `DockKeeper --diagnostics` gives you its pid, or use `pkill -9 -x DockKeeper`.

## [0.9.1] — 2026-07-28

Second public beta. The headline is an install-path fix that v0.9.0 users cannot see but do feel.

### Fixed

- **The app now carries its own notarization ticket.** v0.9.0 stapled only the DMG, and `brew install --cask` copies `DockKeeper.app` out of the image — so every first launch had to reach Apple's Gatekeeper service online. The pipeline now notarizes and staples the `.app` *before* packaging, then the DMG: two tickets, verified from inside the shipped image.
- `Scripts/package-dmg.sh` refuses to package an un-stapled app and re-mounts the finished image to confirm the ticket survived.

### Added

- `Scripts/release.sh` drives the whole build → notarize app → package → notarize DMG sequence in one invocation, validating the signing identity once and asserting a postcondition between every step.
- The CI no-networking-symbols gate now checks both binaries (app and CLI) for high-level networking APIs, raw socket syscalls, and linked networking frameworks.

### Changed

- App and CLI share one settings domain.
- Privacy claims audited to match the build exactly (security-audit follow-ups).

## [0.9.0] — 2026-07-24

First public release: a free, open-source, native macOS utility that keeps your Dock on the edge and display you chose. Signed and notarized (Developer ID, hardened runtime, stapled ticket).

### Added

- **Edge lock** (Bottom / Left / Right) with flicker-free live restore and automatic recovery after sleep, wake, and display changes — retry ladder, burst coalescing, and an oscillation guard that refuses to fight other software.
- **Preferred-display pinning**, including left/right Docks with *Displays have separate Spaces* **on** (the macOS default).
- **Display fingerprinting** that survives docks, adapters, and UUID churn — and never guesses between identical monitors.
- Opt-in **Keep windows in place** after a pin (the app's only permission, Accessibility, strictly optional).
- **Pause** for 15 min / 1 hour / until resumed, plus an optional ⌃⌥⌘D hotkey (off by default).
- Opt-in **hide the Dock while screen sharing**.
- Automation: `dockkeeper` CLI, `dockkeeper://` URL scheme, Apple Shortcuts intents.
- Menu-bar-only app (`.accessory`, no Dock icon of its own); **Launch at Login** via `SMAppService`.
- Distribution: notarized DMG on GitHub Releases and a Homebrew cask (`blamechris/tap/dockkeeper`).

### Known beta limits (why 0.9, not 1.0)

- The multi-monitor hardware test matrix is still being completed; preferred-display pinning is best-effort and partly unverified on real hardware.
- A bottom Dock can't be pinned while *separate Spaces* is on (macOS limitation — DockKeeper explains instead of fighting).
- Shortcuts-app discovery of the intents lands in v1.1; the `dockkeeper://` URL scheme works today.

[Unreleased]: https://github.com/blamechris/DockKeeper/compare/v0.9.5...HEAD
[0.9.5]: https://github.com/blamechris/DockKeeper/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/blamechris/DockKeeper/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/blamechris/DockKeeper/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/blamechris/DockKeeper/compare/v0.9.1...v0.9.2
[0.9.1]: https://github.com/blamechris/DockKeeper/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/blamechris/DockKeeper/releases/tag/v0.9.0
