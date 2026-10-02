# DockKeeper

> **Experimental fork (macald):** investigates a left Dock staying on the
> laptop when the preferred/main LG is to its right. This branch detects and
> reports the mismatch; **it does not yet move the Dock to that internal edge**.
> [Measurements and limitations](docs/spikes/side-dock-display.md).
> Local development builds are ad-hoc signed, **not notarized**; the upstream
> release badges and installation instructions below refer to the original app.

**Free, open-source macOS utility that keeps your Dock on the edge and display you chose.**

[![CI](https://github.com/blamechris/DockKeeper/actions/workflows/ci.yml/badge.svg)](https://github.com/blamechris/DockKeeper/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/blamechris/DockKeeper)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/blamechris/DockKeeper?include_prereleases)](https://github.com/blamechris/DockKeeper/releases)

<p align="center">
  <img src="docs/images/dock-snap-back.gif"
       alt="Screen recording: the macOS Dock sits on the left edge of the screen, then DockKeeper automatically returns it to the bottom edge."
       width="720">
</p>
<p align="center"><em>DockKeeper returning the Dock to its configured bottom edge — displaced here with
<code>defaults write … && killall Dock</code>, snapped back in under two seconds.</em></p>

**No subscriptions, no telemetry, no ads, no required permissions.**

> 🚧 **v0.9 public beta** — feature-complete for v1.0; the multi-monitor
> hardware test matrix is still being worked through. Signed and notarized.

## Why DockKeeper

macOS loves to relocate the Dock — after sleep, display changes, or when you least expect it. DockKeeper watches for those events and puts the Dock back on your preferred edge and display, silently. Compared to the usual workarounds:

- **No Dock restart.** The classic fix — `defaults write com.apple.dock orientation left && killall Dock` — kills and relaunches the Dock every time. DockKeeper repositions it live through the `CoreDock` API, flicker-free, and keeps the `defaults`/`killall` route only as a runtime fallback.
- **Event-driven, not a polling loop.** It reacts to sleep, wake, display, and preference events instead of running a timer.
- **Nothing taken on trust.** No telemetry and no network code — and CI fails the build if a networking symbol, raw socket syscall, or networking framework shows up in either binary ([the gate](.github/workflows/ci.yml), [privacy statement](PRIVACY.md)).
- **No required permissions.** Everything core runs with zero privacy-gated permissions. Two optional features — Keep windows in place, and Keep a bottom Dock on my preferred display — ask for Accessibility, and only if you turn them on.
- **It won't fight your Mac.** An oscillation guard backs off instead of dueling other Dock-moving software, and cases macOS doesn't allow (a bottom Dock pinned while *separate Spaces* is on) get an explanation instead of a fight.

An evidence-labeled, feature-by-feature comparison with the commercial alternative in this space lives in [docs/parity-assessment.md](docs/parity-assessment.md).

## Screenshots

| The menu-bar menu | Preferences ▸ Dock |
|---|---|
| ![DockKeeper's menu-bar dropdown with Enabled checked and items for Lock Edge, Preferred Display, Launch at Login, and Preferences.](docs/images/still-menu-dropdown.png) | ![DockKeeper's Preferences window on the Dock tab, with the Lock Edge picker set to Bottom.](docs/images/still-preferences-dock-tab.png) |

| Dock pushed to the left edge… | …and back on its configured bottom edge |
|---|---|
| ![A macOS desktop with the Dock displaced to the left edge of the screen.](docs/images/still-dock-displaced-left.jpg) | ![The same desktop after DockKeeper restored the Dock to the bottom edge.](docs/images/still-dock-restored-bottom.jpg) |

*Stills from the same session as the recording above: the Dock is moved off its configured edge (simulated with `defaults`/`killall`), and DockKeeper puts it back.*

## Install

**Download:** grab the notarized `DockKeeper-x.y.z.dmg` from [Releases](https://github.com/blamechris/DockKeeper/releases), drag `DockKeeper.app` to Applications (required for Launch at Login), and optionally copy `dockkeeper` somewhere on your `PATH`.

**Homebrew:**

```sh
brew install --cask blamechris/tap/dockkeeper
```

### Upgrading

Quit DockKeeper from its menu-bar icon before installing a new version, then open
it again afterwards. macOS sees a replaced bundle as a new app, and DockKeeper
will not run two copies at once — so a new copy opened alongside a running old
one exits silently, and the old one stays in charge until it is quit or the Mac
restarts.

**Requirements:** macOS 14+ · Apple Silicon (primary) or Intel (best effort).

## Features

- Lock the Dock to **Bottom**, **Left**, or **Right** — flicker-free live repositioning
- Automatic recovery after sleep, wake, display plug/unplug, resolution and arrangement changes — with burst coalescing, a retry ladder for slow wakes, and an oscillation guard that refuses to fight other software
- **Preferred display (best-effort):** attempt to keep the Dock on a chosen monitor. Left/right placement is attempted with separate Spaces on or off, but may fail at internal edges between displays. This fork reports observed mismatches or unknown placement. A bottom Dock with separate Spaces on uses the opt-in guard below.
- Displays recognized by a **multi-signal fingerprint** (survives docks, adapters, and UUID churn; never guesses between identical monitors)
- **Keep windows in place** (opt-in): restores your window layout after a display pin — one of the two features that use a permission (Accessibility), strictly optional
- **Keep a bottom Dock on my preferred display** (opt-in): holds the pointer clear of the bottom edge on your other displays so macOS is never asked to move the Dock there. Needs Accessibility, two or more displays, and a bottom-edge lock. It does not move the Dock back, and where one screen sits above another it leaves only the overlapping strip unguarded — your pointer's route between them — standing down entirely only when that leaves nothing to guard
- **Pause** (15 min / 1 hour / until resumed) for temporary Dock moves, with an optional global hotkey (⌃⌥⌘D, off by default)
- **Hide the Dock while screen sharing** (opt-in)
- Automation: `dockkeeper` CLI, a `dockkeeper://` URL scheme, and Apple Shortcuts intents
- Menu-bar app that stays out of your way (`.accessory` — no Dock icon of its own); **Launch at Login** via Apple's supported `SMAppService`
- Opt-in, bounded, local-only diagnostics file for bug reports — nothing ever leaves your Mac ([privacy statement](PRIVACY.md))

> **How pinning works:** macOS ties the Dock to the *main* display, so pinning
> re-bases which display is main. With separate Spaces **off** that also moves
> the menu bar (expected); with it **on** (default), every display keeps its own
> menu bar. Side-Dock placement also depends on the arrangement (see the fork
> measurements above); a bottom Dock can't be pinned in
> that mode, and DockKeeper says so instead of fighting the OS.
>
> **A bottom Dock cannot be *moved back* once macOS hands it to another
> display** — that is settled, and every relocation mechanism was tested on real
> hardware. But it can be **prevented from leaving**, by guarding the pointer
> gesture that triggers the hop. That is what **Keep a bottom Dock on my
> preferred display** (Preferences ▸ Advanced, off by default) does: it holds
> the pointer a few points clear of the bottom edge on your *other* displays,
> so the summon never completes. It needs Accessibility, at least two displays
> and a bottom-edge lock; earlier builds said it switches off the bottom hot corners
> there, but on the one rig measured a guarded corner still fired, so that claim
> is withdrawn ([#99](https://github.com/blamechris/DockKeeper/issues/99)); and where one screen sits above another it leaves the
> overlapping strip unguarded, because that strip is how your pointer travels
> between them — the parts of the edge that overhang, with nothing beneath them,
> are guarded normally. If you would rather not use it, a left/right edge or turning the macOS
> setting off both still work. Evidence in
> [the spike](docs/spikes/separate-spaces-pinning.md) and
> [ADR-015](docs/decision-log.md). Both halves are measured with a control: the
> clamp holds the pointer, and a real pointer cannot summon the Dock across
> while it is on. What is *not* measured is what it costs in CPU over a long
> session — see the CHANGELOG's *Known beta limits*.
>
> **This change is permanent, and turning DockKeeper off does not undo it.**
> Pinning writes the display arrangement the same way System Settings does, so
> your chosen display stays the main one after you disable or uninstall
> DockKeeper. That is deliberate — silently rearranging your displays at quit
> would be worse — but it means the setting outlives the app. To put it back,
> drag the white menu-bar strip in System Settings › Displays › Arrange.
> **Edge locking alone changes nothing permanently**; only preferred-display
> pinning does.

### Planned

- Follow mouse / active window / active app
- Raycast extension; Shortcuts app discovery (the intents exist; the metadata packaging lands in v1.1 — the URL scheme works today)

## Automation

The CLI and the app share one settings store, so either can drive the other:

```sh
dockkeeper lock left
dockkeeper unlock
dockkeeper status         # your configured settings
dockkeeper status --live  # what the running copy is actually holding
```

`dockkeeper status` reports your *configured* state and works whether or not
DockKeeper is running. `dockkeeper status --live` asks the copy that *is*
running what it holds: the settings it has in memory, whether it sees the
Accessibility permission, whether the bottom-Dock guard's pointer tap is armed,
and whether any of that disagrees with the settings on this Mac — an external
`defaults write` to the bottom-guard setting never reaches a running app, so the
two can drift apart. With nothing running it says so and prints no guard state,
rather than guessing at one. Exit codes: `0` live and agreeing, `3` nothing
published, `4` the publisher is gone, `5` the record could not be read, `6` live
but diverging.


The same commands are available as a URL scheme, for Shortcuts, Raycast, Alfred,
or anything else that can open a URL:

```
dockkeeper://lock?edge=bottom|left|right
dockkeeper://unlock
dockkeeper://pause              (until resumed)
dockkeeper://pause?minutes=15   (capped at 24h)
dockkeeper://resume
```

> **Note on the URL scheme:** it is unauthenticated by design — any process on
> your Mac that can open a URL can unlock or pause DockKeeper, with no prompt.
> The worst case is that your Dock stops being held in place, and anything able
> to run `open` on your Mac can already do more than that. It reads and changes
> nothing else, and it is never reachable from the network. If you would rather
> not have the surface at all, delete the `CFBundleURLTypes` key from
> `DockKeeper.app/Contents/Info.plist` — everything else keeps working.

## Build & Run

Building from source needs a Swift 6 toolchain (as declared in [Package.swift](Package.swift)):

```sh
# Build everything
swift build

# Run the menu-bar app
swift run DockKeeper

# Use the CLI (build product is `dockkeeper-cli`; ships as `dockkeeper`)
swift run dockkeeper-cli status
swift run dockkeeper-cli lock left

# Run tests
swift test
```

### Build the app bundle

SwiftPM produces a bare executable; the bundle script wraps it into a proper
`DockKeeper.app` (with `Info.plist` + entitlements) and ad-hoc code-signs it:

```sh
# Build dist/DockKeeper.app
Scripts/build-app.sh            # release; use "debug" for a faster loop

# Build and launch it
Scripts/run-app.sh

# One-shot status report (handy for bug reports)
dist/DockKeeper.app/Contents/MacOS/DockKeeper --diagnostics
```

That report's `Live state:` row says whether the DockKeeper that is actually
running agrees with the rest of it: every other row is re-derived from this
Mac's settings by the process you just ran, which cannot see what a running app
holds. `dockkeeper status --live` prints the same comparison in full.


> **Launch at Login note:** macOS registers login items through Background Task
> Management, which requires the app to live in **`/Applications`** with a full
> signature. From a dev build directory (or with an ad-hoc signature) the status
> reads `notFound` and the app tells you to move it to Applications. Everything
> else — menu bar, edge lock, preferred display — works from anywhere.

## Architecture

```
DockKeeperCore   — shared engine (no UI deps; used by app + CLI)
├── Dock         — DockController, DockMonitor, CoreDock bridge, orientation model
├── Display      — DisplayManager (UUID-stable display identification)
└── Core         — Settings, logging
```

`DockKeeper` is the menu-bar app (SwiftUI `MenuBarExtra` + preferences); `dockkeeper-cli` is the command-line front end. The Dock is repositioned via the private `CoreDock` C API (`CoreDockSetOrientationAndPinning`), resolved at runtime with `dlsym` so a future macOS change degrades gracefully to the `defaults write com.apple.dock orientation` + `killall Dock` fallback.

### Documentation

The design docs under [`docs/`](docs/) are the contract for this repo (see [AGENTS.md](AGENTS.md)):

- [Behavior specification](docs/behavior-specification.md) — what the app does, edge case by edge case
- [Technical design](docs/technical-design.md) — architecture and mechanisms
- [Decision log](docs/decision-log.md) — ADRs, including the one ratified private-API exception
- [Parity assessment](docs/parity-assessment.md) — evidence-labeled comparison with the commercial alternative
- [Release checklist](docs/release-checklist.md) — the signed/notarized two-ticket release pipeline
- [CHANGELOG.md](CHANGELOG.md) — release history

## Contributing, security, license

- [CONTRIBUTING.md](CONTRIBUTING.md) — build, test, and PR conventions
- [SECURITY.md](SECURITY.md) — how to report a vulnerability (privately, please)
- [PRIVACY.md](PRIVACY.md) — the "nothing ever leaves your Mac" statement, and how to verify it yourself
- MIT © 2026 blamechris — see [LICENSE](LICENSE)
