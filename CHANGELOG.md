# Changelog

All notable changes to PlayolaPlayer are documented here. This project follows
[Semantic Versioning](https://semver.org/). Versions correspond to git tags,
which Swift Package Manager consumers pin to. Pre-1.0, breaking changes bump the
minor version.

## 0.21.0-beta.2

Pre-release for the Phase 5 render path. The new backend is **dormant by
default** — apps that don't opt in get the exact same runtime behavior as
0.20.x. Merging/pinning this version does not change what listeners hear;
flipping the backend on is a separate, server-flagged app-side step gated on
the device QA matrix.

### Added

- **Sample-buffer render backend (AirPlay-2 long-form), opt-in.** A second
  render path built on a custom software `TimelineMixer` feeding one
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer`, so a
  Playola station routes as AirPlay-2 **long-form** audio (HomePod / Apple TV /
  Sonos multi-room) — something the `AVAudioEngine` path cannot do. Selected
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
    compensation for cross-device simultaneity
    (`outputLatencyCompensation`) — the SDK still touches `AVAudioSession`
    **nowhere** (the seam-invariant test now also covers the new files).
- **`PlayolaRenderBackend`** public enum (`.legacyEngine` / `.sampleBuffer`)
  and **`isRenderBackendLocked`** for QA UIs.

### Fixed

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
