# Changelog

All notable changes to PlayolaPlayer are documented here. This project follows
[Semantic Versioning](https://semver.org/). Versions correspond to git tags,
which Swift Package Manager consumers pin to.

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
