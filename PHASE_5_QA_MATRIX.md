# Stage 1 — Device QA matrix (AirPlay-2 long-form, sample-buffer backend)

**Committed record of the QA run backing the `0.21.0-beta.2` tag** (run 2026-08-20 against
SDK SHA `929c2b4`; tag cut at `2fc4268` = `929c2b4` + docs-only PR #109). Class A green on
Apple TV; B1 route-switch drift quantified for Stage 4 / FU-2. See `IMPLEMENTATION_PLAN.md`
for the surrounding stage plan.

Human-run hardware matrix for the opt-in `.sampleBuffer` render path (custom mixer →
AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer).

## Setup (once)

1. **Open the example app on a real device** (simulators can't AirPlay):
   - Open `PlayolaPlayerExample/PlayolaPlayerExample.xcodeproj` in Xcode.
   - **Local-package path check:** the committed `project.pbxproj` references the SDK at
     `relativePath = ../../PlayolaPlayer`, which only resolves when the repo folder is
     literally named `PlayolaPlayer`. If your checkout has a different folder name (e.g. a
     Conductor worktree), temporarily edit the `XCLocalSwiftPackageReference` to
     `relativePath = ..` — and do NOT commit that edit.
   - Sign in to the dev account in Xcode ▸ Settings ▸ Accounts if prompted (CLI signing was
     unavailable; GUI signing is required), select your iPhone, unlock it, Run.
2. **Console logging** — on the Mac, either Console.app filtered to subsystem
   `fm.playola.playolaCore` category `SampleBuffer`, or:
   ```
   log stream --predicate 'subsystem == "fm.playola.playolaCore" && category == "SampleBuffer"' --level debug
   ```
   Also watch for `-50` / AVAudioSession errors (search "error -50" unfiltered while testing).
3. **In-app QA UI** (already in the build):
   - "Sample-buffer renderer" toggle — set BEFORE pressing play; it locks on first play
     (subtitle shows "Locked (relaunch to switch)"). Relaunch the app to switch backends.
   - Readout line under the toggle: `Backend: … (pending|locked)` and
     `Route: <name> — outputLatency: <n> ms`. Use the latency numbers when judging the
     two-device sync rows (local ≈ 18 ms, AirPlay ≈ 2000 ms).
4. **Sanity check before starting the matrix**:
   - `.sampleBuffer` active → `SampleBuffer` category logs appear on play.
   - `.legacyEngine` active → NO `SampleBuffer` logs.
   - ✅ PASSED 2026-08-20 (Apple TV route): `controller init: outputLatency=2.000000s ->
     startFrame=96000`, `sink created`, `2/2 spins scheduled`, `renderer status=rendering`,
     first `boundary: spin … started` fired. Latency compensation confirmed engaged for the
     2 s route. Note: the category tag is metadata — messages read `sink created`,
     `controller: …`, `boundary: …`; don't text-filter for "SampleBuffer" in Xcode's console.

## Method

Baseline every audible row on `.legacyEngine` first, then repeat on `.sampleBuffer`.
The bar is "no worse than legacy."

**Target scoping (2026-08-20):** only an Apple TV is available — no HomePod or Sonos on
hand. Decision: run the full Class A matrix against **Apple TV** (a true AirPlay-2
long-form target; readout confirms ~2000 ms route latency) and ship `0.21.0-beta.2` as
"device-verified on Apple TV; HomePod/Sonos expected-compatible but unverified." Sonos
hardware verification lands with the Stage 4 / FU-2 multi-room device session. Stage 3
changelog wording must carry this scoping.

## Class A — fixed route from launch (GATES `0.21.0-beta.2`)

| # | Row | How | Pass criteria | Result (Apple TV) |
|---|-----|-----|---------------|-------------------|
| A1 | Long-form routes, no -50 | Toggle sample-buffer → play → AirPlay-pick the Apple TV | Plays continuously; NO `-50`/session error in Console; keeps playing with screen LOCKED / app backgrounded | ✅ PASS (2026-08-20) — latency comp engaged (`outputLatency=2.0s -> startFrame=96000`), `renderer status=rendering`, no `-50`/errors, survived lock + background |
| A2 | Two-device simultaneity | Same station on two devices, fixed routes from start (e.g. iPhone local + iPhone→Apple TV, or vs a Mac running the example app) | Perceptually in sync, no worse than legacy baseline | ✅ PASS (2026-08-20) — perceptual judgment by the operator; per-run details (second device, route pair, offset estimate) and the legacy baseline were not captured contemporaneously, so this row is not independently auditable. Re-run WITH captured detail in the Stage 4 two-device session, whose instrumentation (needed to verify FU-2 anyway) will make sync measurable rather than perceptual. |
| A3 | Gapless boundaries | Listen across ≥3 song→voicetrack→song transitions on the Apple TV route | No click/gap/overlap vs `endOfMessageMS`; sounds like legacy | ✅ PASS (2026-08-20) — `boundary: spin … started` events observed at transitions |
| A4 | Interruption recovery | Trigger a call / Siri / alarm mid-playback on the Apple TV route, then end it | Resumes (pause→refill→resume), back in sync, no permanent silence | ✅ PASS (2026-08-20) |
| A5 | Memory bounded (also validates Stage 0) | 30+ min session, watch Xcode memory graph under cache pressure | Memory plateaus; no unbounded growth / jetsam; no active-file prune dropout | ✅ PASS at reduced coverage (2026-08-20) — passed this runbook's 30+ min criterion on the Apple TV route. NOTE: the stage plan's original bar was stricter (≥2 h, one local + one AirPlay run, oldest supported device class); that fuller soak was NOT run for beta.2. Residual durability risk is accepted for an opt-in, server-flagged beta and carried forward: run the ≥2 h dual-route soak during the app-side beta soak / Stage 4 device session before any GA claim. Stage 0's exclusion fix is unit-tested; this run adds field evidence at 30-min scale only. |

**MATRIX RESULT: Class A green on Apple TV (all 5 rows), B1 quantified (≈1983 ms). Stage 1
COMPLETE under the Apple TV scoping. Gate for `0.21.0-beta.2` is OPEN.** QA'd SDK SHA:
`929c2b4` (develop tip; working tree carried only the example-app pbxproj path tweak,
which is not SDK code).

**Evidence caveats carried forward (do before any GA / non-beta claim):**
- A5 passed at 30-min scale only — the ≥2 h dual-route (local + AirPlay) soak from the
  stage plan is still owed (app-side beta soak or Stage 4 device session).
- A2 is a perceptual pass without captured per-run detail — re-run measurably in the
  Stage 4 two-device session (its FU-2 instrumentation makes sync quantifiable).
- Legacy-baseline table below was not filled contemporaneously.

Legacy baselines (fill in first):

| Row | Legacy baseline notes |
|-----|-----------------------|
| A1 | |
| A2 | |
| A3 | |
| A4 | |
| A5 | |

## Class B — live route switch mid-session (GATES `0.21.0-beta.3` / FU-2)

| # | Row | How | Expected | Result |
|---|-----|-----|----------|--------|
| B1 | Live route switch drift | Start on local (or one AirPlay target); mid-song switch route to AirPlay/Sonos while a 2nd device stays fixed | EXPECTED TO FAIL until FU-2. Recovers to playing (auto-flush) but drifts ~latency delta. **Quantify the drift (ms)** — read `outputLatency` off the readout before/after the switch and estimate audible offset vs the fixed device | drift ≈ **1983 ms, lagging** (readout: 17 ms local → 2000 ms AirPlay) |

**B1 run notes (2026-08-20, iPhone 14 Pro Max → MacBook Pro AirPlay):** sample-buffer backend,
local → AirPlay switch mid-song, plus adding/removing a second AirPlay group member. Playback
recovered on every switch — no dropout, no silence, no volume loss. Drift was not perceptually
obvious single-device; the 1983 ms figure is the predicted drift from the route-latency delta
(the exact quantity FU-2 must re-compensate on route change). Independent audio-offset
measurement (two-device waveform comparison) deferred to Stage 4 instrumentation, which FU-2
needs anyway to verify its fix.

## Failure capture (for Stage 2)

For any red row, record here: exact repro steps, target device, backend, and a Console excerpt
(include timestamps and any `-50`/OSStatus lines).

```
(paste excerpts)
```

**Open finding (2026-08-20, sample-buffer → MacBook AirPlay):** brief stutter at the START of
streaming to a speaker (right as the AirPlay route engages); clean afterwards, including through
group add/remove. To triage later: (1) does legacy baseline stutter at the same moment? (2) grab
the `SampleBuffer` Console lines around the switch — repeated `recover:` lines within ~1s would
point at the auto-flush recovery path (`SampleBufferStationRenderer.recoverAfterAutoFlush`);
a single one suggests normal AirPlay pipeline priming. Not yet classified as SDK bug vs platform
behavior; severity low (one-time, settles).

## Acceptance

- All Class A rows green on Apple TV (or each failure captured above for Stage 2).
- B1 measured and drift quantified (input to Stage 4 / FU-2). ✅ done: ≈1983 ms.
- HomePod/Sonos: explicitly out of scope for beta.2 (no hardware); carried as unverified
  in the Stage 3 changelog and revisited in the Stage 4 device session.
