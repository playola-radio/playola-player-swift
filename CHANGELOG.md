# Changelog

All notable changes to PlayolaPlayer are documented here. This project follows
[Semantic Versioning](https://semver.org/). Versions correspond to git tags,
which Swift Package Manager consumers pin to.

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
