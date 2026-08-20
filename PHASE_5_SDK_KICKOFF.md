# Phase 5 SDK implementation — kickoff brief (fresh context)

Paste this into a fresh context working in **this SDK worktree**:
`/Users/brian/playola/PlayolaPlayer-phase5` on branch `briankeane/phase-5-sample-buffer-renderer`
(base: host-only `develop`). It is self-contained. **You will NOT merge.** End with a final report.

## What this is
Phase 5 of the host-owned-audio refactor: replace the SDK's local render path (`AVAudioEngine` +
per-spin `AVAudioPlayerNode` graph — `SpinPlayer` / `PlayolaMainMixer`) with a **custom software mixer →
one `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`** path so Playola stations cast as
**AirPlay-2 long-form** to Sonos / HomePod / Apple TV. Only the render **sink** changes; the SDK's
scheduling / download / generation / state orchestration is reused.

## Read first (authoritative, already on this branch)
- **`PHASE_5_PLAN.md`** — the full plan: architecture, ownership boundary, wall-clock→PTS math, mid-file
  join, starvation rules, the 13-test coverage list (centerpiece = the pure mixer), the rollout seam,
  risks, implementation order (§9), and the eng-review + outside-voice corrections (§11–12). **Follow it.**
- **`PHASE_5_PLAN.md` §13 — slice-0 device findings** (the spike results that de-risked this).

## Decisions already LOCKED (do not re-litigate)
1. **Renderer:** `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` (not AVPlayer+composition).
2. **Mixer:** a **custom `TimelineMixer`** that decodes/resamples/sums/ducks PCM ourselves and emits
   interleaved stereo float32 — NOT AVAudioEngine-manual-render. (Both were spiked on device and route
   AirPlay long-form; custom mixer chosen for the unit-testable render timing that is an explicit Phase 5
   goal, no AVAudioEngine format/lifecycle coupling — the spike hit `-10868` + lifecycle crashes on the
   engine path — and no interleave-conversion tax. Engine-manual's only edge, reusing AU fades, is moot
   since fades reduce to `Spin.volumeAt*`.)
3. **Concurrent ducked mixing is IN slice 1** — Playola spins OVERLAP (voicetrack ducked over song); the
   mixer sums concurrent `SpinBufferSource`s with per-spin fade gain. NOT a sequential playlist.
4. **Fade fidelity:** reproduce the legacy **~1.5s AU ramp** behavior (NOT stepwise `volumeAtMS`); the
   parity test compares against the ramped envelope. Fade math derives from `Spin.volumeAt*` (single source).
5. **Route-change recovery = pause → reset → refill → resume** (Apple's "pause" option). The
   "keep-running, re-enqueue-from-now" option FAILS at real AirPlay latency (~2000ms measured on device:
   audio lands in the past → silence). Confirmed on hardware. This is §4.1's re-anchor.
6. **Render callback is decode/IO-free AND allocation-light/lock-free**: `SpinBufferSource` pre-decodes
   into a bounded PCM ring buffer on its own executor; the mixer only sums ready PCM.
7. **Rollout seam:** `configure(renderBackend:)` instance setter (default `.legacyEngine`, release-locked
   after first `play()`). Legacy path stays byte-for-byte default at runtime. App flips it via a
   server flag later (separate PR).
8. **Enqueue API:** the classic `requestMediaDataWhenReady` + `enqueue` is CORRECT on iOS 18 (verified
   against the SDK headers — NOT deprecated; the `sampleBufferReceiver` Codex flagged is video-only).
9. **AVAudioEngine internal connections require deinterleaved float32** (interleaved throws `-10868`) — a
   spike lesson; irrelevant to the custom mixer (which emits interleaved for CMSampleBuffer directly).

## Where to start (Lane A, TDD — pure, no CoreMedia)
`Sources/PlayolaPlayer/Player/SampleBuffer/` (SwiftPM auto-includes; no pbxproj). Tests in
`Tests/PlayolaPlayerTests/`. SDK convention: plain swift-testing `#expect` (zero external deps — do NOT
add swift-custom-dump). Reuse the existing `DateProviderMock` for the clock.

1. **`TimelineMapper`** (started — `SampleBuffer/TimelineMapper.swift`): wall-clock `Date` → output frame
   index on the mix timeline. **Write `TimelineMapperTests` first** to lock it (airtime→frame,
   already-airing→negative frame, frame↔date round-trip, scheduleOffset shift).
2. **`FadeEnvelope`**: per-sample gain derived from `Spin.volumeAt*`, reproducing the ~1.5s ramp; test
   asserts parity with the ramped legacy envelope.
3. **`TimelineMixer`** (CENTERPIECE): `(activeSpins, outputFrameRange) -> interleaved PCM`. Sums
   overlapping sources with per-spin gain, clip-protects, missing source ⇒ silence (no stall). Tests:
   two overlapping sources sum correctly; missing source ⇒ silence; mid-file join offset.

Then Lanes B–D per §9: `SpinBufferSource` (AVAssetReader→PCM ring buffer + `AVAudioConverter` resample),
`RenderSynchronizing`/`SampleBufferRendering` protocol seam + live CoreMedia adapters + fakes,
`SampleBufferStationRenderer` (requestMediaDataWhenReady loop, pause-refill-resume on auto-flush,
generation supersede, boundary→state), `configure(renderBackend:)` + `StationRenderPipeline` strategy,
keep/extend `SessionSeamInvariant`. `swift build` + `swift test` green.

## Constraints (from PHASE_5_PLAN + repo)
- **Host owns the session:** SDK touches `AVAudioSession` NOWHERE (the seam-invariant test enforces it).
- **Preserve the outward contract:** `PlayolaStationPlayer.State` (`.idle/.loading/.playing/.paused/.error`)
  + `PlayolaStationPlayerDelegate`, byte-stable.
- **Zero external SPM deps.** Swift 6 tools / Swift 5 language mode. iOS 18 / tvOS 18 / macOS 14.
- Build/test with `swift build` / `swift test` in the worktree (macOS). Device verification is a separate
  human step (AirPlay matrix) — see §8 / §13.
- **DO NOT MERGE.** When green: bump SDK version, tag a pre-release (e.g. `0.21.0-beta.1`) for the app to
  pin. The app integration (server flag) is a separate held PR against `develop`.

## Housekeeping
- The **spike** (`PlayolaPlayerExample/PlayolaPlayerExample/Phase5SpikeView.swift` + its button in
  `ContentView.swift`) is throwaway — delete it once the real render path lands. It proved AirPlay
  long-form routing + the recovery model; it does not use the SDK.
- The example app's local package path was locally tweaked to `..` (worktree-local, uncommitted) so it
  builds against this worktree; `../../PlayolaPlayer` is correct for a normal checkout — do not commit that line.

## Final report
Report: what shipped in the SDK, `swift test` results, the pre-release tag cut, Codex adversarial pass
verdict (run `/codex review` then `/codex challenge` on the diff before declaring done), and confirmation
that nothing is merged. Then hand back so the app-integration PR (server flag) can be written.
