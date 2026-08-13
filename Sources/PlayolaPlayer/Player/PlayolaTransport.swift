import Foundation

// HTTP/3-preferring transport for Playola API hosts.
//
// Some users sit behind networks that interfere with TCP connections to
// *.playola.fm specifically (host/SNI-targeted resets, SSL-inspection
// middleboxes) while leaving UDP/QUIC alone. The previous mitigation capped
// URLSession to TLS 1.2 to shrink the ClientHello — but that is still TCP, so
// it never helped these users (Sentry `tls13_probe` diagnosis `http3Rescues`:
// both TLS 1.2 and TLS 1.3 over TCP fail while HTTP/3 succeeds).
//
// Instead we prefer HTTP/3 (QUIC) on Playola API requests via
// `assumesHTTP3Capable`, which races QUIC on the very first request (no prior
// Alt-Svc discovery needed) and falls back to HTTP/2 over TCP automatically
// when QUIC is unavailable.
//
// S3 audio downloads are deliberately NOT marked HTTP/3 — S3 speaks only
// HTTP/1.1 / HTTP/2 over TCP, so a QUIC hint there is pointless. They use a
// plain, uncapped default configuration.
enum PlayolaTransport {
  /// Uncapped session for first-party Playola API calls (schedule fetch,
  /// listening-session reports). Replaces the old TLS-1.2-capped `tls12Session`.
  static let APISession: URLSession = URLSession(configuration: .default)

  /// Marks a request to a Playola API host (`admin-api.playola.fm`) as
  /// HTTP/3-preferring. Every request the SDK issues to its API host should be
  /// routed through here.
  static func preferHTTP3(_ request: inout URLRequest) {
    request.assumesHTTP3Capable = true
  }

  /// A request to a Playola API host with HTTP/3 already preferred.
  static func makeAPIRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    preferHTTP3(&request)
    return request
  }

  /// Uncapped configuration for S3 audio downloads. Deliberately NOT HTTP/3 and
  /// deliberately NOT TLS-capped. Callers layer their own timeouts on top.
  static func makeDownloadConfiguration() -> URLSessionConfiguration {
    return URLSessionConfiguration.default
  }
}
