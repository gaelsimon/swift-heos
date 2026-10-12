import Foundation

/// Shared `URLSession` with strict per-request and per-resource timeouts.
/// Used when fetching device description XML during SSDP enrichment so an
/// unresponsive host on the LAN cannot stall discovery for the default 60 seconds.
enum HEOSURLSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    /// A browse page waits on local servers, so a slow one costs at most this much.
    static let localServer: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 1.5
        return URLSession(configuration: config)
    }()
}
