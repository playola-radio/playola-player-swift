# Phase 5 — AirPlay-2 long-form renderer (sample-buffer path)

**Status:** PLAN — architect pass complete (Codex consult 019fec2f), pending plan-eng-review.
**SDK branch:** `briankeane/phase-5-sample-buffer-renderer` (base: host-only `develop`).
**Ship posture:** build now, HOLD, merge after 7.5.0 graduates. Flag-gated, prod-off by default.

This is the dedicated Phase 5 plan called for by `~/playola/shared/PLAYOLA_AUDIO_OWNERSHIP_PLAN.md`
(the "separate track" section). It changes **only the render path**. It preserves the Phase 0–3
ownership contract verbatim.

---

## 1. Goal

Replace the SDK's local render path (`AVAudioEngine` + per-spin `AVAudioPlayerNode` graph) with a
render path built on **`AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`**, so a
Playola station:

- Plays the existing wall-clock rolling schedule with correct timing (no drift over a long session).
- Preserves **concurrent, ducked mixing** (voicetrack over song with per-spin volume envelopes) —
  Playola's core feature, not a nicety.
- Routes as **AirPlay-2 long-form** to Sonos / HomePod / Apple TV / multi-room (the whole point:
  `AVAudioEngine` output does not; the sample-buffer renderer goes through the media stack that does).

## 2. Why sample-buffer, not AVPlayer + AVMutableComposition

The schedule is a **live, rolling, partially-known, absolute-time, multitrack** stream: the next
10 minutes may change every 20s, downloads finish async, and multiple spins are audible at the same
instant and must be mixed with independent per-sample gain. `AVMutableComposition` wants a mostly-known
timeline and is not a live software mixer — mutating an active composition while AirPlay buffers is
where stalls, stale buffered tails, seek/preroll weirdness and boundary drift live. Once you are
already producing a mixed program PCM stream (which concurrent ducking forces), `AVSampleBufferAudioRenderer`
is the correct sink. (Confirmed twice with Codex, including after the concurrent-mixing correction.)

**Mental model:** not playlist assembly. A **wall-clock multitrack mixer** whose single program feed
is rendered through the media stack.

## 3. Load-bearing constraints (do NOT break)

1. **Host owns the session.** The SDK touches `AVAudioSession` **nowhere** (no `AudioSessionManager`
   on this branch; source-scan invariant test enforces zero `AVAudioSession.sharedInstance` /
   `.setCategory(` / `.setActive(` in `Sources/`). The new renderer needs no session of its own —
   that is exactly what makes it AirPlay-2 long-form. The **host** must set
   `.playback` / `.default` / `policy: .longFormAudio` then `setActive(true)`. Do **not** cargo-cult
   `.allowAirPlay` / `.allowBluetooth` / `.mixWithOthers` category options — invalid long-form
   combinations produce OSStatus -50. Document host requirements in the README.
2. **Wall-clock scheduling stays.** Spins scheduled at absolute `airtime: Date`; async download ahead;
   rolling 20s poll / 10-min lookahead; `playGeneration` supersession. All engine-agnostic; it stays.
3. **One outward state/Now-Playing contract.** SDK reports state only via
   `PlayolaStationPlayer.State` (`.idle` / `.loading(Float)` / `.playing(Spin)` / `.paused(Spin)` /
   `.error`) through `@Published state` + `PlayolaStationPlayerDelegate`. Keep byte-stable. Now-Playing
   / MediaPlayer writing stays in the **app** (Phase 2/3), not the SDK.
4. **Zero external SPM deps.** Swift 6 tools / Swift 5 language mode. iOS 18 / tvOS 18 / macOS 14.

## 4. Architecture

```
Schedule + async downloads (existing FileDownloadManaging)
  -> SpinBufferSource          (one per spin: AVAssetReader over the downloaded file, PRE-DECODES
                                ahead of the render position into a BOUNDED per-source PCM ring
                                buffer on its own queue/actor; owns decode state. [eng-review A2])
  -> TimelineMixer             (pure + real-time-safe: for output frame range [pts, pts+dur), find all
                                spins whose [airtime, endtime] intersects, read each source's ALREADY-
                                DECODED PCM from its ring buffer at the matching offset, apply that spin's
                                per-sample fade gain, SUM, clip-protect, emit ONE mixed PCM CMSampleBuffer
                                with absolute PTS. NEVER decodes / touches IO in this path. [A2])
  -> SampleBufferStationRenderer  (owns the media stack: ONE AVSampleBufferAudioRenderer +
                                   ONE AVSampleBufferRenderSynchronizer; drives
                                   requestMediaDataWhenReady; boundary/time observation)
  -> PlayolaStationPlayer      (unchanged responsibilities: schedule fetch, rolling window, downloads,
                                generation, public State + delegate)
```

**Real-time boundary [eng-review A2]:** `requestMediaDataWhenReady` runs the enqueue block on a serial
queue with a real-time deadline. Decode (AVAssetReader + codec + file IO) is unpredictable and must
happen **ahead** of that callback. So: `SpinBufferSource` decodes into a bounded PCM ring buffer on its
own executor; the render-callback mixer only **sums ready PCM** and must never call AVAssetReader or do
IO. A unit/integration test asserts the render path performs zero decode/IO. A source not yet decoded
for the requested range contributes silence (§4.4), never blocks.

**Ownership boundary (the important line):**
- `PlayolaStationPlayer` owns station/session-facing state + generation.
- `SampleBufferStationRenderer` owns the media stack (renderer + synchronizer).
- `TimelineMixer` owns **audio truth** (what samples play when, at what gain).
- `SpinBufferSource` owns per-file decode state.
- **Host** owns `AVAudioSession`.

### 4.1 Wall-clock → synchronizer timeline

Pick a station-timeline epoch once per play generation:

```
anchorDate = dateProvider.now()
stationTime(for: date) = CMTime(seconds: (date - anchorDate) + scheduleOffset, timescale: 1_000_000_000)
spinPTS(spin)          = stationTime(for: spin.airtime)
bufferPTS              = outputPTS   (mixed output is authored on the station timeline directly)
start:  synchronizer.setRate(1.0, time: stationTime(for: dateProvider.now()))
```

Mixed output buffers are authored **on the station timeline**, so each spin contributes to output
frame ranges where its `[airtime, endtime]` window intersects. No per-spin PTS juggling on the sink —
the mixer resolves overlap.

**Drift + simultaneity policy [eng-review A1 — simultaneity is a TOP priority: audio must match true
wall-clock as closely as possible, and match the legacy path so two listeners on different backends
hear the "live" moment together].** The synchronizer timebase advances on the audio-hardware / AirPlay
device clock, which drifts from `Date()` wall clock over a long session. A single never-corrected anchor
would let that drift grow unbounded (the thing this feature must avoid). Policy:
- **Audio is the render master, wall-clock is the schedule master; re-anchor at each spin boundary.**
  Within one spin, drift is sub-audible; at each spin start, recompute `stationTime(for: nextSpin.airtime)`
  from fresh wall clock so error never accumulates across spins. Corrections land at boundaries (natural
  cut points), not mid-spin, so there is no mid-spin discontinuity.
- **Latency-compensated initial anchor.** AVSampleBufferAudioRenderer + AirPlay add a fixed output
  presentation delay. The initial `setRate(_:time:)` anchor must offset by measured render/AirPlay
  latency so a sample authored at `stationTime(airtime)` actually *reaches the speaker* at `airtime`.
- **Cross-backend parity.** During the flag soak, some listeners run the legacy engine and some the
  sample-buffer path. Measure end-to-end presentation latency for BOTH (local + AirPlay) on device and
  reconcile the anchors so the two backends present the same instant within a small tolerance. This is a
  **device-measured** parameter (see §8 risk 1 / device checklist), not a guess.
- A unit test asserts boundary re-anchor keeps computed spin PTS within tolerance of wall clock over a
  simulated long session with an injected drifting clock.

**Re-anchor safety [outside-voice C1].** Do NOT naively call `setRate(1.0, time:)` at a boundary while
future buffers are already enqueued — moving the timebase under queued PTS jumps the synchronizer. Two
safe options, decided at implementation against real behavior: (a) keep the enqueue queue **shallow**
(only ~the read-ahead window) so re-anchor = flush-tail + re-enqueue is cheap and inaudible at the cut
point; or (b) never move the timebase — keep ONE monotonic synchronizer timeline and correct drift by
nudging only FUTURE spins' authored PTS in the mapping (bounded, at boundaries). (a) is simpler and
preferred if the queue is shallow anyway (it must be, for the memory bound §8.8). This is a real design
task, not a free line — it partially overlaps the "rescheduling surgery" the cut line defers, so scope it
to *tail flush + re-enqueue at a boundary*, not arbitrary future-window edits.

**Latency parity caveat [outside-voice C4].** The SDK is forbidden to read `AVAudioSession`/route state
(host-owned), so it cannot itself measure output/route latency per device. Latency compensation must
therefore be either (i) fed in by the host (which owns the session/route), or (ii) derived from the
synchronizer's own presentation timing, or (iii) accepted as the synchronizer's default. This is an
**open device-investigation item**, not a solved design — the plan must not claim latency parity is
designed; it claims it is *measured and reconciled on device*, with the mechanism chosen from (i)–(iii)
after the slice-0 proof.

### 4.2 Mid-file join (mandatory for slice 1)

"Start a station now" almost always lands mid-spin. Compute current station time, find the currently
airing spin(s), start each `SpinBufferSource`'s reader at `now - spin.airtime`, and begin mixing from
there. Fade envelope starts at `spin.volumeAtDate(now)` (existing `Spin` math). No special audio-node
"play now" op. Without this it's a future-play demo, not a station player.

### 4.3 Concurrent ducked mixing (slice 1 IN)

Per-spin `startingVolume` + `fades` evaluated per sample (or per short ramp segment) and summed. This
is intelligibility, not polish: without ducking a voicetrack and its bed play at equal volume = garbage.
Fixed mix format: **stereo float32 PCM at one chosen sample rate** (all sources resampled to it during
decode via `AVAudioConverter`). Clip-protection on the sum. **No AU automation, no processing taps** —
we are leaving the engine world; do not sneak it back in.

**Fade math is single-source [eng-review Q1]:** the gain applied per sample is derived from the existing
`Spin.volumeAtMS` / `volumeAtDate` — the SAME truth the legacy engine uses (via AU automation) — never a
reimplemented curve. `FadeEnvelope` is a thin adapter (sample offset → ms/date → `Spin.volumeAt*`) that
may precompute a ramp table *from that same math* if per-sample calls profile too slow; it is kept only
if profiling demands it, otherwise the mixer calls `Spin.volumeAtDate` directly. A unit test asserts
`FadeEnvelope` output equals `Spin.volumeAt*` at sampled offsets so the two backends duck identically.

### 4.4 Starvation (mandatory)

The synchronizer timeline **never waits for late downloads once playback has started**:
- A source not ready for a requested output range contributes **zeroes (silence)**.
- A late source may join only at the current timeline offset — **never backfill** old audio.
- During initial startup only, may stay `.loading` until a small startup deadline if the primary
  current spin is missing. After playback begins, **no global stall** — one slow voicetrack download
  cannot freeze the station.
- Report late misses (spin id, requested PTS, lateness) via the existing error reporter.

### 4.5 State / boundary events

Reproduce today's "flip to `.playing(spin)` at the boundary" using **synchronizer boundary/time
observers** tied to the real render timeline (better than a raw wall-clock `Timer`). Keep a wall-clock
timer only as a fallback if boundary observers prove unreliable over remote AirPlay routes. State must
tolerate small boundary latency on remote routes. `@Published State` + delegate stay byte-stable.

## 5. Rollout seam (server-flagged, prod-off) — NON-NEGOTIABLE

**SDK side [eng-review A3]:** backend selected via the existing **instance `configure()`** path,
defaults to the proven engine, locked after first `play()`. NOT a `play()` parameter (invites accidental
mid-session switching). Chosen over an `options:`-only init because the app consumes
`PlayolaStationPlayer.shared` pervasively (CarPlay scene, Siri `PlaybackBootstrap`,
`ListeningSessionReporter`, player page) — a per-instance init would force the app to build and thread a
new instance through every `.shared` call site (a large, risky diff in exactly the paths Phases 1–3 just
stabilized). A `configure()`-time setter is an instance method, so the SAME mechanism works on `.shared`
now and on any app-owned instance after a future migration — no rework.

```swift
public enum PlayolaRenderBackend: Sendable { case legacyEngine, sampleBuffer }

extension PlayolaStationPlayer {
  // Set once, before first play(); locked (assertionFailure) once playback has started.
  // Defaults to .legacyEngine. Works on `.shared` and on any future app-owned instance.
  public func configure(authProvider:, baseURL:, renderBackend: PlayolaRenderBackend = .legacyEngine)
}
```

One app-wide player is preserved: CarPlay, the player page, and Siri all drive the same live stream
(same `.shared` instance). Backend selection is orthogonal to instance count.

**Follow-up (NOT in Phase 5):** migrate the app to a single `@Dependency`-provided
`PlayolaStationPlayer` (per-instance, still exactly one live player shared across CarPlay/player page/
Siri) and retire `.shared`. That is the Point-Free-idiomatic, testable long-term shape; it touches every
`.shared` call site so it is its own effort. The `configure(renderBackend:)` setter above is
forward-compatible with it. Captured as a TODO.

**App side (this repo):** a **server-driven** boolean, defaulting **OFF** when the server omits it,
selects `.sampleBuffer`. Mirror the existing precedent — **not a new infra system**:
- Add an optional `Bool?` (e.g. `sampleBufferRendererEnabled`) to an existing launch payload,
  decoded with `decodeIfPresent` so absence ⇒ **false** (mirrors `RewardsProfile.shouldShowWelcomeMessage`).
- Project into a new in-memory `@Shared` key in `State/SharedUserDefaults.swift`
  (`InMemoryKey`, `default: false`, mirrors `welcomeMessageEligible`).
- Read that flag only at the **renderer-selection seam** (where the app constructs/derives the SDK player).
- **NEVER** gate on `Config.shared.environment`. Production must never be the environment where the
  feature is dark by construction. Turning the flag ON for production is a launch-checklist item.

## 6. Test strategy (TDD — render timing unit-testable for the first time)

Wrap **behavior, not Apple class names**, so CoreMedia stays out of unit tests:

```swift
protocol RenderSynchronizing {           // fake records setRate/time, drives observers deterministically
  var currentTime: CMTime { get }
  func setRate(_ rate: Float, time: CMTime)
  func addBoundaryObserver(times: [CMTime], _ block: @escaping () -> Void) -> Any
  func removeObserver(_ token: Any)
}
protocol SampleBufferRendering {          // fake records enqueued RenderBuffers + PTS, toggles readiness
  var isReadyForMoreMediaData: Bool { get }
  func enqueue(_ buffer: RenderBuffer)    // RenderBuffer = our struct: spinID, pts, duration, frameCount, gain meta
  func flush()
}
```

Inject the existing `DateProviderProtocol` mock as the clock. CoreMedia-backed decode/enqueue is
**integration-tested** separately (and validated on device).

**Highest-value unit tests (swift-testing `@Test`/`#expect`):**
1. `TimelineMapper` — absolute airtime → expected output PTS from a fixed anchor date.
2. `TimelineMixer` — two overlapping sources sum correctly at a given output frame range. **(CENTERPIECE)**
3. `FadeEnvelope` — duck-down / hold / up gain correct at sample offsets, AND equals `Spin.volumeAt*`
   at sampled offsets (Q1 single-source parity).
4. `MissingSource` — unavailable source contributes silence and does **not** stall mixed output.
5. `MidFileJoin` — reader starts at elapsed spin offset; absolute PTS preserved.
6. `GenerationSupersede` — stale sources/render callbacks cannot enqueue or publish state.
7. `SessionSeamInvariant` — source-scan still proves zero `AVAudioSession` touches in `Sources/`.
8. `DriftReanchor` **[eng-review A1]** — with an injected drifting clock over a simulated long session,
   boundary re-anchor keeps each spin's computed PTS within tolerance of wall clock (no accumulation).
9. `RenderPathNoDecodeIO` **[eng-review A2]** — the render-callback mix path performs zero decode / file
   IO (fake `SpinBufferSource` asserts its decode entry point is never called from the render queue).
10. `SpinBufferSourceDecode` **[→integration, bundled fixture]** — AVAssetReader decodes a fixture file
    to PCM starting at a requested offset; frame count matches expectation.
11. `FormatNormalization` **[→integration]** — a 44.1 kHz source and a 48 kHz source both resample to the
    fixed mix format via `AVAudioConverter`; mixed output stays sample-aligned.
12. `BoundaryToState` — a fired boundary observer maps to `.playing(spin)` on `@Published State` +
    delegate, byte-stable with the legacy path; tolerates small boundary latency.
13. `BackendSelection` — `configure(renderBackend:)` selects the backend, defaults `.legacyEngine`, and
    is **locked in release** after first `play()` (precondition/no-op, NOT just `assertionFailure`
    — [outside-voice C5]).

The **centerpiece** is #2/#3: the pure mixer `(activeSpins, outputFrameRange) -> PCM`.

**Device-only (cannot be unit-tested — see §8 risk 1 + device checklist):** AirPlay-2 long-form routing
to HomePod/Apple TV/Sonos (no -50), latency parity vs the legacy engine (A1 simultaneity), gapless at
real spin boundaries, and interruption/route behavior under the new renderer.

## 7. First-slice cut line

**SLICE 0 — hardware de-risk spike FIRST [outside-voice C16/Tension 1&2].** Before building the pipeline,
prove the sink and pick the mixer:
- Stand up ONE `AVSampleBufferAudioRenderer` + ONE `AVSampleBufferRenderSynchronizer` fed **generated
  PCM** (sine/noise), with the host session at `.playback`/`.longFormAudio`. Prove on device it routes
  **long-form to a HomePod/Apple TV (no -50)** and measure end-to-end presentation latency.
- In the same spike, stand up an **`AVAudioEngine` manual-rendering** variant (reuse existing
  `SpinPlayer` graph + AU fades, pull PCM, feed the same renderer) far enough to judge reuse + latency.
- **Decision gate:** commit to **custom `TimelineMixer`** vs **engine-manual-render** based on the spike
  (fade reuse, latency, engine-quirk cost). Everything below assumes the custom mixer; if engine-manual
  wins, fades come from the existing AU ramps (Tension 2 parity is then automatic) and §4.3/FadeEnvelope
  collapse to the engine path.
- Rationale: if the sink does not route long-form as assumed, we learn it in a half-day, not after
  building decode/mix/fades/drift/flagging.

**IN (slice 1 — the minimal shippable/AirPlay-provable station):**
- Runtime backend selection; default `.legacyEngine`; `.sampleBuffer` behind the server flag.
- ONE `AVSampleBufferRenderSynchronizer` + ONE `AVSampleBufferAudioRenderer`.
- Software `TimelineMixer`; fixed stereo float32 output format.
- Multiple concurrent `SpinBufferSource`s via existing `FileDownloadManaging`.
- Absolute wall-clock → PTS mapping; mid-file join for the currently-airing spin(s).
- Per-spin `startingVolume` + `fades` (ducking) — IN.
- Missing overlapping source ⇒ silence (no post-start stall).
- Boundary-driven `.playing(spin)` transitions; `State` + delegate unchanged.
- Stop / play generation supersession; basic renderer-error propagation.
- **TestFlight proof:** routes as long-form to HomePod/Apple TV when the host sets `.longFormAudio`.

**OUT (later slices):**
- N renderers / renderer-`.volume` automation / processing taps.
- Polished song-to-song **crossfades** beyond existing fade data; limiter/mastering beyond clip-protection.
- Partial-flush "rescheduling surgery" for changed future windows (slice 1 appends; stop/restart on
  severe mismatch).
- Multi-room latency tuning.
- Gapless perfection for badly-authored source files (encoder priming/padding).
- `PlayolaMainMixer` tap / mixed-buffer delegate parity.
- Public API churn beyond backend selection.

## 8. Top risks (attack these in adversarial review + on device)

1. **AirPlay-2 only proven on hardware** — simulator means little. Device matrix is mandatory.
2. **Codec priming/padding** — decoded PCM exposes real file boundaries; MP3/AAC priming can add
   gaps/clicks. Measure decoded frame counts vs `endOfMessageMS`; treat gapless as a **measured**
   property, not an assumption.
3. **Starvation** — renderer readiness ≠ audio present; missing-source-silence path must be exercised.
4. **Boundary observer latency** over remote routes — state must tolerate it.
5. **Timing drift / simultaneity** vs wall clock over long sessions — resolved by boundary re-anchor +
   latency-compensated anchor + cross-backend latency parity (§4.1, A1). Simultaneity is a TOP priority;
   verify on device that legacy and sample-buffer listeners present the same instant within tolerance.
6. **Session/-50** — any accidental SDK session touch, or wrong host category options, breaks long-form.
7. **Contract regressions** — `State`/delegate byte-stability; generation supersession; zero-session invariant.
8. **Memory / jetsam** [eng-review P1] — pre-decode ring buffers add steady audio memory on an app with
   OOM/jetsam history. Keep read-ahead small/bounded (~1–2s/source, named constant), stream-decode (not
   whole-file), free superseded buffers immediately, cap concurrent sources; measure footprint on device.

## 9. Implementation order (TDD, held branch)

1. Pure types + tests first: `TimelineMapper`, `FadeEnvelope`, `TimelineMixer` (tests 1–4) — no CoreMedia.
2. `SpinBufferSource` decode (AVAssetReader → PCM at offset) — integration test on a bundled fixture.
3. `RenderSynchronizing` / `SampleBufferRendering` protocols + live CoreMedia adapters + fakes.
4. `SampleBufferStationRenderer` wiring the synchronizer + requestMediaDataWhenReady loop; mid-file join,
   generation supersede, boundary→state (tests 5–6).
5. `PlayolaRenderBackend` + `configure(renderBackend:)` setter (A3, default `.legacyEngine`, lock after
   first `play()`, test 13); route `PlayolaStationPlayer` internals through a `StationRenderPipeline`
   strategy; legacy path stays default and untouched at runtime.
6. Drift re-anchor (test 8), render-path no-decode/IO (test 9), format normalization (test 11),
   boundary→state (test 12); keep/extend `SessionSeamInvariant` (test 7). `swift build` + `swift test` green.
7. Bump SDK version, tag pre-release (e.g. `0.21.0-beta.1`) for the app to pin. **Do not merge.**

## 10. App integration (this repo, held PR — separate brief)

- Pin BOTH pbxproj `playola-player-swift` refs to the pre-release SDK.
- Add the server `Bool?` flag + in-memory `@Shared` key (§5); construct the SDK player with
  `.sampleBuffer` only when the flag is true.
- Host session already sets `.longFormAudio` (Phase 1 `AudioSessionCoordinator`) — verify options don't
  trip -50 with long-form.
- New `.swift` files hand-registered in `project.pbxproj`; tests swift-testing + `.freshSharedState`;
  don't append to the 1000-line `StationPlayerTests.swift`. `make lint`. Build with
  `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/...`. Open PR vs `develop` and **HOLD**.

## 11. Eng-review outputs

### What already exists (reuse, don't rebuild)
- `Spin.volumeAtMS` / `volumeAtDate` / `startingVolume` / `fades` — **single source of fade truth**; the
  new mixer reuses it (Q1), never reimplements the curve.
- `Spin.playbackTiming` / `Schedule.current(offset:)` — wall-clock date math + rolling window; unchanged.
- `DateProviderProtocol` (+ mock) — the injectable clock for all timeline/drift tests.
- `FileDownloadManaging` (+ `MockFileDownloadManager`) — async download + cache; the new path consumes it
  unchanged (feeds `SpinBufferSource`).
- `PlayolaStationPlayer` orchestration — schedule fetch, 20s poll, 10-min lookahead, `playGeneration`
  supersession, `@Published State` + delegate — **engine-agnostic, stays**. Only the render sink swaps.
- `SessionSeamInvariant` source-scan test — extended, not rewritten.
- Host `.longFormAudio` session ownership (app `AudioSessionCoordinator`, Phase 1) — already in place.

### Failure modes (each new codepath: realistic prod failure → covered?)
| Codepath | Realistic failure | Test | Error handling | User sees |
|---|---|---|---|---|
| Render callback (A2) | decode stalls real-time loop → dropout | T9 no-decode/IO + T4 | ring buffer + silence fill | brief silence, not a freeze |
| Late/missing source (§4.4) | download not done at airtime | T4 | silence, join at current offset | that source missing, station continues |
| Drift (A1) | audio vs schedule desync over hours | T8 | boundary re-anchor | in-sync within tolerance |
| Boundary observer (§4.5) | fires late on AirPlay | T12 | wall-clock fallback timer | small state latency, tolerated |
| Backend select (A3) | flipped mid-session | T13 | lock after play (assertionFailure) | no change (locked) |
| Codec priming (risk 2) | click/gap at real join | device matrix | measure vs `endOfMessageMS` | **device-verify** |
| Session -50 (risk 6) | wrong host options w/ long-form | T7 + device | zero SDK session touch | **device-verify** |
| Memory (P1) | ring buffers → jetsam | device footprint | bounded read-ahead | **device-verify** |

**Critical gaps (no test AND no error handling AND silent): none.** The device-only rows have explicit
handling designs; they are unverifiable off-device by nature, not silent gaps — device matrix is mandatory.

### Worktree parallelization
Slice 1 is largely **sequential within the SDK** (one render pipeline, shared types). Two small parallel
lanes exist once the pure core lands:
- **Lane A (foundation, must land first):** `TimelineMapper`, `FadeEnvelope`, `TimelineMixer` + tests
  T1–T4, T8 (pure, no CoreMedia). Everything depends on this.
- **Lane B (after A):** `SpinBufferSource` decode + `AVAudioConverter` normalization (T10–T11) —
  independent of Lane C.
- **Lane C (after A):** `RenderSynchronizing`/`SampleBufferRendering` protocols + fakes + boundary→state
  (T12) — independent of Lane B.
- **Lane D (after B+C):** `SampleBufferStationRenderer` + `configure(renderBackend:)` wiring (T9, T13).
- **App integration (separate repo/PR):** parallel to SDK once the pre-release tag exists.

Conflict flag: Lanes B and C both eventually touch `SampleBufferStationRenderer` (Lane D) — keep D
single-owner. Recommend: A → (B ∥ C) → D, then app PR.

### Implementation Tasks
Synthesized from this review. P1 blocks ship; P2 same branch; P3 follow-up.
- [ ] **T-A1 (P1)** — timeline: boundary re-anchor + latency-compensated anchor + cross-backend parity
  hook. Surfaced by A1. Files: `SampleBufferStationRenderer`, `TimelineMapper`. Verify: test T8 + device latency parity.
- [ ] **T-A2 (P1)** — pre-decode ring buffer in `SpinBufferSource`; render path decode/IO-free.
  Surfaced by A2. Files: `SpinBufferSource`, `TimelineMixer`. Verify: T9 + T4.
- [ ] **T-A3 (P1)** — `configure(renderBackend:)` setter, default legacy, lock after play.
  Surfaced by A3. Files: `PlayolaStationPlayer`. Verify: T13.
- [ ] **T-Q1 (P2)** — `FadeEnvelope` derives from `Spin.volumeAt*` (adapter/cache, no reimpl).
  Surfaced by Q1. Files: `FadeEnvelope`. Verify: T3 parity assertion.
- [ ] **T-P1 (P2)** — bounded read-ahead constant, stream-decode, free superseded buffers.
  Surfaced by P1. Files: `SpinBufferSource`. Verify: device footprint measurement.
- [ ] **T-DEV (P1, human)** — device matrix: AirPlay long-form (no -50) to HomePod/Apple TV/Sonos,
  latency parity vs legacy, gapless at real boundaries, interruption/route. Surfaced by risks 1/2/6/8.

### TODOs (deferred, captured with context)
- **App per-instance player migration** [P3] — replace `PlayolaStationPlayer.shared` with a single
  `@Dependency`-provided instance (one live player shared across CarPlay/player page/Siri). Why: testable,
  no global state, Point-Free-idiomatic; makes backend selection clean at construction. Blocked by: touches
  every `.shared` call site. The `configure(renderBackend:)` setter is forward-compatible, so this is not
  urgent. (From A3.)

## 12. Outside-voice corrections (Codex plan review)

An independent Codex pass on the finalized plan surfaced these; all folded in. Cross-model tensions were
decided by the user (Tension 1 → C spike-both; Tension 2 fade → A legacy ramps).

- **C1 Deprecated enqueue API — REJECTED after verification.** Codex claimed
  `requestMediaDataWhenReady`/`enqueue` is deprecated in favor of a `sampleBufferReceiver`. Checked the
  Xcode-26.5 iOS SDK headers directly: `AVSampleBufferAudioRenderer : <AVQueuedSampleBufferRendering>`
  still exposes `enqueueSampleBuffer:` / `requestMediaDataWhenReadyOnQueue:usingBlock:` /
  `isReadyForMoreMediaData` / `flush` with **NO `API_DEPRECATED`** annotation (available ios(11.0)+).
  `sampleBufferReceiver` is a *video*-renderer concept (only appears in `AVAssetWriterInput.h`), not the
  audio path. So the classic `requestMediaDataWhenReady` + `enqueue` IS the correct current surface for
  the audio renderer; the `SampleBufferRendering` protocol wraps it. (Example of the outside voice being
  confidently wrong — verified, not adopted.)
- **C2 Re-anchor vs queued buffers.** Folded into §4.1 (shallow queue + tail-flush/re-enqueue, or
  future-PTS-only nudging).
- **C3 Boundary observers ≠ acoustic presentation** over AirPlay — already handled by the wall-clock
  fallback + latency tolerance (§4.5); sharpened here.
- **C4 Latency parity is not yet a design** and the SDK can't read route/session. Folded into §4.1 as an
  open device-investigation item (host-fed / synchronizer-timing / accept-default), not a claimed design.
- **C5 Release lock.** `configure(renderBackend:)` uses a real release-mode lock (precondition/no-op),
  not just `assertionFailure` (test 13).
- **C6 Fade parity claim was false.** Legacy plays ~1.5s **AU ramps** + mid-file `volumeAt(_:)` lookahead,
  not stepwise `volumeAtMS`. Decision (Tension 2 = A): reproduce the legacy **ramped** behavior; the Q1
  parity test compares FadeEnvelope against the **ramped** envelope, not `volumeAtMS`. Moot if
  engine-manual-render wins slice 0.
- **C7 Mid-file join must be sample-exact.** `AVAssetReader` start for compressed formats is not
  frame-exact; decode-and-**trim** to the exact output frame + account for codec priming/padding.
- **C8 `endOfMessageMS` ≠ decoded PCM duration.** Use the correct duration for render-end / current-spin
  classification; do not treat `endOfMessageMS` as the PCM end (risk of truncated tails).
- **C9 Late-join reality.** `FileDownloadManaging` yields **complete** local files, not streaming bytes,
  so a late source can only join after full download **plus** decode read-ahead — not instantly.
- **C10 Ring depth ↔ starvation are coupled.** Tune read-ahead depth (P1) and starvation together **on
  device** for AirPlay jitter; 1–2s may need to grow, traded against the jetsam bound. One decision, not two.
- **C11 Render path must be allocation-light + lock-free**, not merely IO-free — CMSampleBuffer/CMBlock
  alloc, `Data` bridging, format conversion, ring locks all cause dropouts. Test 9 asserts no-alloc/no-lock
  in the hot path (use preallocated buffer pools).
- **C12 CMSampleBuffer mechanics must be specified** in slice-0/impl: exact ASBD + channel layout,
  `CMAudioFormatDescription`, timing entries, contiguous frame counts, monotonic PTS, silence-buffer
  generation, and backing-memory lifetime. `RenderBuffer` is the test struct; the live adapter owns these.
- **C13 Renderer lifecycle error handling** (its own concern): renderer `.failed` status, receiver
  enqueue failure/result, `flush` requests, `AVAudioEngineConfigurationChange`/media-services-reset, route
  loss, stop-with-pending-request, and observer/request teardown. Add to slice 1 (maps to `State.error`).
- **C14 "Only render sink swaps" understates the refactor.** `PlayolaStationPlayer` registers engine-config
  recovery and `SpinPlayer` owns graph nodes; the sample-buffer backend must replace/bypass those, gated by
  the strategy so the legacy path is byte-for-byte unchanged at runtime.
- **C15 Device-only fallback is explicit:** if long-form routing or latency parity fails on device, the
  handled fallback is **flag stays OFF in production** (the rollout is server-flagged precisely for this).
  That is the design, not an unhandled gap.

---

### Provenance
Architected via Codex consult (session `019fec2f-2eba-7433-8b9c-1f7226d86111`), two rounds: initial
render-path design, then a correction after verifying Playola spins **overlap and mix with per-spin
ducking** (pool of concurrent `SpinPlayer`s + `startingVolume`/`fades`), which moved from a
sequential single-renderer model to a **software-mix-into-one-renderer** model with ducking IN slice 1.
Then a full `/plan-eng-review` (6 findings A1/A2/A3/Q1/P1 + coverage audit) and an independent Codex
outside-voice pass (§12) with 3 user-decided cross-model tensions.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | not run (optional; infra/audio, not a product-scope change) |
| Codex Review | `/codex` (consult ×2 + plan review) | Independent 2nd opinion | 3 | issues_found | 2 architect rounds + outside-voice: 15 corrections folded in |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (PLAN) | 6 issues, 0 critical gaps, 0 unresolved |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | n/a (no UI; SDK render path) |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | n/a |

- **CODEX:** 2 consult rounds shaped the architecture (sample-buffer + concurrent-ducked software mix);
  outside-voice pass added 15 corrections (deprecated API, re-anchor safety, fade-parity falsity,
  sample-exact join, allocation-free render, lifecycle errors, latency-parity caveat, slice-0 spike).
- **CROSS-MODEL:** 3 tensions decided by user — mixer approach = spike both behind slice-0 then commit;
  fade fidelity = reproduce legacy ~1.5s ramps; (drift/simultaneity = boundary re-anchor + latency parity).
- **UNRESOLVED:** 0.
- **VERDICT:** ENG CLEARED — plan ready to implement (TDD, held branch). CEO/Design reviews n/a for an
  SDK render-path change. Next: slice-0 hardware de-risk spike, then implement per §9.
