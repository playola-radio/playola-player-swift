import Foundation

// TEMPORARY: Global TLS 1.2 cap.
//
// On iOS 26, URLSession sends a TLS 1.3 ClientHello that includes the X25519MLKEM768
// post-quantum hybrid key share (~1.6 KB). Some users sit behind middleboxes
// (antivirus SSL inspection, parental-control routers, captive portals, etc.) that
// drop the larger ClientHello and surface as NSURLErrorSecureConnectionFailed (-1200).
// Capping URLSession to TLS 1.2 keeps the ClientHello small enough for these
// middleboxes to pass through.
//
// Every URLSession in this library is routed through `tls12Session` (or a
// configuration derived from `makeTLS12Configuration()` when a delegate is needed)
// so audio downloads, schedule fetches, and listening-session reports all succeed
// on these networks.
//
// REVERT WHEN: Apple ships an iOS 26 fix (watch 26.5+ release notes) OR exposes
// a supported opt-out for the post-quantum hybrid key share so we can keep TLS 1.3.
internal func makeTLS12Configuration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.default
  configuration.tlsMaximumSupportedProtocolVersion = .TLSv12
  return configuration
}

internal let tls12Session: URLSession = URLSession(configuration: makeTLS12Configuration())
