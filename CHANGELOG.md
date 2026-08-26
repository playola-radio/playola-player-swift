# Changelog

All notable changes to PlayolaPlayer are documented here. This project follows
[Semantic Versioning](https://semver.org/). Versions correspond to git tags,
which Swift Package Manager consumers pin to. Pre-1.0, breaking changes bump the
minor version.

## Unreleased

### Fixed

- **First play no longer sits silent after loading reaches 100% when the
  startup deadline beat the first decode.** On a first play over a
  slow-to-establish route (notably AirPlay 2's one-time route bring-up), the
  2s startup deadline starts the renderer before the airing spin's first
  decode lands, so the queue fills with up to the full 3s enqueue horizon of
  silence — and, because queued buffers are immutable, that silence had to
  drain in real time before any real audio at the write cursor was heard.
  Worse, the decode window was frozen at its ingest-time offset, so after
  running silently the refill landed entirely behind the live playhead and
  mixed to yet more silence. Now, the moment playback becomes publishable —
  the late audible decode, or the trusted boundary crossing of an
  early-decoded future first spin — the controller flushes the queued
  audio, re-anchors the write cursor to the live playhead, and refills; the
  catch-up decode starts from the playhead (not the frozen ingest offset)
  and spans the enqueue horizon plus the decode lead, so the refill carries
  real audio all the way to the new horizon. The recovery runs at most once
  per play and only in the deadline-started, not-yet-published window, so it
  can never flush audio that is already publishably playing; the fast path
  (decode before the deadline) is untouched. Joining from the live playhead
  skips only audio that was physically unhearable during the silent gap —
  playback stays wall-clock synced with the station schedule, as always.
  `.legacyEngine` and the public API are unchanged.

## 0.21.0-beta.4

### Fixed

- **The startup deadline no longer reports `.playing` during the silent
  pre-decode hole.** If the airing spin's download outlived the 2s startup
  deadline, the renderer started with no audio decoded and `onPlaybackStarted`
  fired immediately — publishing `.playing` while the renderer was still
  silent, with `onLoadProgress` gated off. A slow download read as "loading
  finished" followed by 1–1.5s of real dead air. The renderer still starts at
  the deadline (§4.4 — a slow/missing download can never hang the station),
  but `onPlaybackStarted` now only fires once audio is actually imminent: at
  the first currently-audible decode, immediately if the airing spin's
  download/decode fails after the deadline already started the renderer (so
  the state machine can never sit in `.loading` forever behind a renderer
  that's already running), or — for a malformed airing spin with no download
  URL at all — at the deadline itself, since no download/decode will ever
  exist for it. Loading progress now covers the deadline-started hole too —
  it keeps flowing until playback is actually published, not just until the
  renderer starts — and is retired the moment a LATER spin's boundary is
  crossed (`onSpinStarted`), so a later spin becoming audible first can't
  leave the airing spin's stale download progress regressing state back to
  `.loading`. The airing spin's own boundary crossing does not retire
  progress or count as a publish, and is no longer forwarded to
  `onSpinStarted` at all while playback is unresolved — the renderer fires
  that boundary from the spin's scheduled position, independent of whether
  its own decode has landed, so treating it as proof of real audio (either by
  retiring progress or by notifying the owner) would reopen the exact
  silent-hole bug this fix exists to close — UNLESS the airing spin's decode
  has already landed at least once by the time its boundary fires, in which
  case the crossing is trusted: `Schedule.current` can hand back a first spin
  that hasn't started airing yet (nothing currently on air), whose decode can
  land well before its own airtime, and its later boundary crossing is the
  only thing that will ever publish for it. `onPlaybackStarted` (audible
  decode or failure) remains this spin's transition trigger when no decode
  has landed at all yet. A later spin's boundary crossing is unaffected and
  still publishes immediately, as before. The "currently-audible decode" gate
  is now also identity-checked (`spinID == airingSpinID`), not just
  position-checked: on a high-latency route (e.g. AirPlay, ~2s of
  compensation) a later spin scheduled within that latency window could
  decode before the airing spin's own download/decode finished and satisfy
  the position check too, publishing early for the wrong spin. Decode-ahead
  is driven by the renderer's own position rather than eagerly, so for a
  future-scheduled first spin the boundary can also fire *before* its decode
  lands — the audible-position check would then drop that late decode
  forever too, since a future spin's fixed scheduled position never
  satisfies it. A late-landing decode after such a boundary crossing is now
  recognized as the last remaining publish trigger and fires immediately.
  Finally, the airing spin's own boundary crossing is now also dropped once
  playback has already been published by any other path (audible decode or
  the failure fallback) — the boundary observer has no memory of whether it
  already fired for a given spin, so without this it could forward
  `onSpinStarted` a second time for the exact same spin already published via
  `onPlaybackStarted`, republishing a stale duplicate `.playing(firstSpin)`.
  A future-scheduled first spin's own failure is now also deferred the same
  way: previously any airing-spin failure published immediately once the
  renderer was running, which was correct for a spin already on air but wrong
  for a first spin scheduled minutes out — it would show `.playing` for audio
  that wasn't due yet. The failure now publishes immediately only if the
  spin's own scheduled position has already been reached (or its boundary
  already crossed); otherwise it waits for that boundary crossing, which
  publishes via `onPlaybackStarted` (not `onSpinStarted` — a failed spin never
  has real audio). This deferral applies regardless of which order the
  failure and the startup deadline land in: a failure that lands *before* the
  deadline previously bypassed the same-position check when the deadline
  later started the renderer, publishing early for the same reason — both
  orderings now go through one shared gate. That shared gate's due-check was
  itself re-evaluated: it compared a position snapshot frozen at ingest
  against a fixed latency constant, so a first spin scheduled slightly in the
  future whose failure landed well before the startup deadline could still
  read as "not yet due" at the deadline even though real time had by then
  already passed its scheduled airtime — deferring publish to a boundary
  crossing that had, in wall-clock terms, already happened. The check now
  re-derives the airing spin's due status from the current time on every
  call instead of reusing the ingest-time snapshot. `.legacyEngine` and the
  public API are unchanged.

## 0.21.0-beta.3

### Fixed

- **The `.sampleBuffer` backend now reports download progress while loading.**
  Previously it published `.loading(0)` once at `play()` and then nothing
  until the first decode fired `.playing` — a listener could sit on a bare
  `.loading(0)` for the whole initial download with no visible progress. The
  currently-airing spin's download now drives `.loading(progress)` exactly
  like the legacy path's `loadSpinWithProgress`, via a new internal
  `onLoadProgress` seam on `SampleBufferPlaybackController`. Only that first
  spin reports — concurrently-downloading upcoming spins never do — and once
  playback has actually started, later/racing progress callbacks are dropped
  so the published state can never regress from `.playing` back to
  `.loading`. The `.legacyEngine` path and the public API are unchanged.
- **The `.sampleBuffer` backend now validates the currently-airing spin and
  cleans up a failed station switch, matching the legacy path.** A malformed
  airing spin (missing `downloadUrl`) now fails `play()` with `.error` instead
  of starting the pipeline into silent dead air under the wrong metadata — the
  same `validateSpinForScheduling` check the `.legacyEngine` path already made.
  The airing spin is chosen from a single schedule snapshot and threaded into
  the controller, so the spin validated and published as `.playing` is exactly
  the one ingested (closing a boundary-crossing TOCTOU). And any `play()` that
  fails after superseding a prior session — malformed spin, no current spins,
  or a schedule-fetch error — now tears the previous sample-buffer controller
  down, so it can't keep rendering audio behind an `.error` state. Download
  progress is also pinned to the airing spin by position rather than id, so a
  later spin carrying a duplicate id can't inherit its progress reporting.

## 0.21.0-beta.2

Pre-release for the Phase 5 render path. The new backend is **dormant by
default** — apps that don't opt in get the exact same runtime behavior as
0.20.x. Merging/pinning this version does not change what listeners hear;
flipping the backend on is a separate, server-flagged app-side step.

**Verification status (what this beta does and does not claim):**

- **Device-verified on Apple TV** (fixed-route AirPlay-2 long-form: routing,
  latency-compensated start, gapless boundaries, interruption recovery, bounded
  memory over a long session). **HomePod and Sonos are expected-compatible but
  unverified** — they speak the same AirPlay-2 long-form protocol, but no
  hardware pass has been run against them yet.
- **Fixed-route only.** Output-latency compensation is read once per `play()`,
  when the playback pipeline starts. A device that switches routes mid-session
  (e.g. local speaker → AirPlay, ~18 ms → ~2000 ms) recovers playback but is
  mis-compensated by the latency delta until the next `play()`. Live
  route-switch re-sync (and with it any broader multi-room simultaneity claim)
  is deferred to `0.21.0-beta.3`.

### Added

- **Sample-buffer render backend (AirPlay-2 long-form), opt-in.** A second
  render path built on a custom software `TimelineMixer` feeding one
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`, so a
  Playola station routes as AirPlay-2 **long-form** audio (device-verified on
  Apple TV; HomePod/Sonos expected-compatible, unverified — see the
  verification status above) — something the `AVAudioEngine` path cannot do. Selected
  via the new `renderBackend:` parameter on `configure(...)` (or the
  `setRenderBackend(_:)` helper): defaults to `.legacyEngine` and locks at the
  first `play()`, so the proven engine path remains the byte-for-byte runtime
  default. Scheduling, downloads, generation supersession, and the outward
  `State`/delegate contract are unchanged — only the render sink is new.
  Highlights of the new path:
  - Wall-clock → PTS timeline mapping with boundary re-anchoring, so audio
    stays in sync with the schedule over long sessions (no cumulative drift).
  - Concurrent ducked mixing (voicetrack over song) driven by the same
    `Spin.volumeAt*` fade truth as the legacy path, reproducing the legacy
    ~1.5s ramps.
  - Decode/IO-free, allocation-light render hot path: per-spin
    `SpinBufferSource`s pre-decode into bounded PCM ring buffers; the mixer
    only sums ready PCM. A source that isn't ready contributes silence — one
    slow download can never stall the station.
  - Mid-file join, route-change recovery (pause → refill → resume, verified on
    hardware against real ~2s AirPlay latency), and host-fed output-latency
    compensation for cross-device simultaneity at play start
    (`outputLatencyCompensation`, read once per `play()` at pipeline start —
    see the fixed-route note above) — the SDK still touches `AVAudioSession` **nowhere** (the
    seam-invariant test now also covers the new files).
- **`PlayolaRenderBackend`** public enum (`.legacyEngine` / `.sampleBuffer`)
  and **`isRenderBackendLocked`** for QA UIs.
- **`setRenderBackend(_:)`** for selecting the backend without calling
  `configure(...)`, and **`outputLatencyCompensation`** for host-fed
  output-latency compensation on the `.sampleBuffer` backend.

### Fixed

- **`pruneCache(maxSize:excludeFilepaths:)` now honors `excludeFilepaths`.**
  The implementation previously ignored the exclusion list (and fire-and-forgot
  the prune inside a `Task`, silently dropping errors), so under cache pressure
  on a long session it could delete an audio file that was actively playing.
  Both render backends pass their active files' paths and were affected. The
  method is now `async throws`: exclusions are honored (with path
  normalization, so `/private/var` vs `/var` forms can't defeat them), excluded
  files still count toward the size total, and deletion errors propagate to the
  caller. Callers implementing `FileDownloadManaging` must adopt the new
  signature.

- **Networks that block Playola over TCP now play via HTTP/3 (QUIC).** Some
  listeners sit behind routers / SSL-inspection middleboxes that interfere with
  TCP connections to `*.playola.fm` specifically (host/SNI-targeted resets)
  while leaving UDP/QUIC alone. The previous mitigation capped URLSession to
  TLS 1.2 to shrink the ClientHello, but that is still TCP, so it never helped
  these users (Sentry `tls13_probe` diagnosis `http3Rescues`: both TLS 1.2 and
  TLS 1.3 over TCP fail while HTTP/3 succeeds). The TLS 1.2 cap is removed and
  the SDK now prefers HTTP/3 (`assumesHTTP3Capable`) on Playola API requests
  (schedule fetch, listening-session reports), which races QUIC on the first
  request and falls back to HTTP/2 over TCP automatically. S3 audio downloads
  are intentionally left uncapped and non-HTTP/3 (S3 has no QUIC). See
  `PlayolaTransport`. (Shipped on the maintenance line as 0.20.3.)

## 0.20.1

### Added

- **`Airing.startTime` / `Airing.endTime` — the show's real on-air window.** Every
  spin returned by `GET /v1/stations/{stationId}/schedule` now carries these two
  fields on its nested `airing` object. `startTime` is the real moment the show
  goes on air (`MIN(spin.airtime)` across the airing's spins, accounting for the
  "lead gap" where preceding content pushes the show later than its slot);
  `endTime` is the real moment it goes off air (`MAX(spin.endOfMessageTime)`,
  floored at `airtime + episode.durationMS`). Both are optional ISO-8601 UTC
  dates — present only on airings from the schedule feed and `nil` elsewhere — so
  the change is additive and source-compatible. `airtime` (the nominal slot) is
  unchanged. Downstream apps can drive a real-time "next show in ~N min" countdown
  off `endTime`. Also available on the 0.19.x line as 0.19.1.

## 0.20.0

This release makes the **host app the sole owner of the `AVAudioSession`.** The
SDK previously configured/activated the session and self-handled interruptions
and route changes; it no longer touches `AVAudioSession` at all. This lets the
SDK coexist cleanly with other audio subsystems in your app (URL streaming,
recording, VoIP) instead of fighting them for the process-global session.

### Removed

- **The SDK no longer manages the `AVAudioSession`.** `AudioSessionManager` is
  gone, `PlayolaMainMixer` no longer exposes `configureAudioSession()` /
  `ensureAudioSessionConfigured()` / `deactivateAudioSession()`, and
  `PlayolaStationPlayer` no longer registers `AVAudioSession.interruptionNotification`
  / `routeChangeNotification` observers. The `handleAudioSessionInterruption(_:)`
  and `handleAudioRouteChange(_:)` methods are removed.

  **Source-breaking — required host changes:**

  1. **Own the session.** Configure and activate it before `play(stationId:)`:
     `try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])`
     then `setActive(true)`. The SDK no longer does this; without it,
     `play(stationId:)` fails when the engine starts (surfaced as `.error`).

  2. **Drive interruptions yourself.** Observe `AVAudioSession.interruptionNotification`
     (and route changes as needed) and call the new `pauseForInterruption()` /
     `resumeAfterInterruption()` (below). Reactivate the session before calling
     resume.

  See the [Audio session](README.md#audio-session) and migration sections of the
  README for copy-paste host setup and a full interruption-handling example.

### Added

- **Host-driven interruption transport.**
  - `PlayolaStationPlayer.pauseForInterruption()` — silences playback,
    cancels scheduling/downloads, and is generation-fenced so in-flight work
    from before the pause can't publish state afterward. Preserves only the
    station identity (wall-clock radio has no frozen position). Idempotent
    across a double-pause.
  - `PlayolaStationPlayer.resumeAfterInterruption() async throws` — restarts the
    engine and replays the interrupted station re-synced to the live wall clock.
    Disarms only on success, so a failed resume (e.g. the host hasn't
    reactivated the session yet) stays retryable.

- **`PlayolaStationPlayer.State` gained a `.paused(Spin)` case.** Published while
  paused for an interruption; the `Spin` carries display metadata (title,
  artist, artwork URL) for the track that was playing. **Source-breaking for
  consumers** that `switch` exhaustively over `State`: add a `case .paused` arm.

- **Engine self-recovery.** The SDK now restarts and re-syncs its own engine
  graph on `AVAudioEngineConfigurationChange` (scoped to the SDK's own engine,
  so a host running a separate `AVAudioEngine` is unaffected). This is engine
  ownership, not session ownership — it touches no `AVAudioSession` API.

## 0.19.0

### Added

- **Bounded retry/backoff on the initial schedule fetch.** `play(stationId:)`
  now retries a failed initial `GET /v1/stations/{id}/schedule` up to 3 times
  with exponential backoff (0.5s / 1s / 2s) before giving up, matching the
  recovery behavior the player already used for spin loading and the ongoing
  schedule poll. Only transient failures are retried — server `5xx` responses
  and an explicit allow-list of connectivity `URLError`s (timeouts, host/DNS,
  connection-lost, etc.). Permanent failures (`404`, decode errors, empty
  schedules, and non-connectivity `URLError`s such as `.badURL`) still fail
  fast. This means a transient backend outage no longer instantly fails a
  station start with no automatic recovery.

### Changed

- **`PlayolaStationPlayer.State` gained a terminal `.error(StationPlayerError)`
  case.** A failed `play(...)` now emits `.loading(0)` when the attempt begins
  and `.error(_)` when it fails terminally (instead of throwing without ever
  changing `state`, which could leave consumers stuck on a loading spinner with
  no signal). `play(...)` still `throws` as before — the new state is emitted
  *in addition to* the thrown error. Cancellation does not produce an `.error`
  state.

  **Source-breaking for consumers** that `switch` exhaustively over `State`:
  add a `case .error` (or `default`) arm. A typical handler treats `.error` as
  a recoverable, retry-able state (show the message, let the user tap play
  again). `StationPlayerError` is now `Sendable`.

- **State transitions are now supersession-safe (last `play()` wins).** Each
  `play(...)`/`stop()` takes a new internal generation; work from a prior
  attempt (its scheduling loop, or a spin whose audio starts later) can no
  longer publish state into a newer attempt. This closes a race where a
  lingering session could overwrite a freshly-emitted `.error` (or `.idle`)
  with `.playing`. Behavioral note: starting a new `play()` supersedes the
  previous session immediately, so a *failed* station switch lands on `.error`
  rather than rolling back to the previously-playing station.

- **`playNow(from:to:)` and `schedulePlay(at:)` are now `async`.** Both `public`
  methods changed from synchronous to `async` so their audio work can run off
  the main thread. **Source-breaking for direct callers**: add `await` at the
  call site (callers must already be in an `async` context, e.g. a `Task`).

## 0.18.0

### Added

- **Network logging seam** for observing the library's JSON API traffic
  (binary audio downloads are intentionally excluded). New public API in
  `PlayolaCore`:
  - `PlayolaNetworkLogEvent` — a `Sendable` value describing a single
    request/response (method, url, request headers/body, status code,
    response body, duration, and any error description). Events are raw and
    unredacted; the consuming app is responsible for redacting sensitive
    values such as `Authorization` headers before storing them.
  - `PlayolaNetworkLogger.handler` — a thread-safe, `Sendable` hook the
    consuming app sets at startup to receive events. `nil` (the default)
    disables logging, leaving behavior and performance unchanged.
  - `PlayolaNetworkLoggingSession` — a transparent `URLSessionProtocol`
    wrapper that times each call and emits an event on both success and
    thrown error without altering return values or rethrown errors.

  The schedule fetch (`PlayolaStationPlayer`) and the listening-session
  reporter (`ListeningSessionReporter`) now route their JSON API calls through
  this wrapper by default. No breaking API changes: existing initializers and
  call sites compile unchanged.
