import Foundation

/// A ContentDirectory on the LAN, named as the device lists it under Local Music.
struct MediaServerEndpoint: Equatable, Sendable {
    let friendlyName: String
    let serviceType: String
    let controlURL: URL
}

/// Finds the media servers the device browses on our behalf.
struct MediaServerDiscovery: Sendable {
    static let searchTarget = "urn:schemas-upnp-org:device:MediaServer:1"

    // MX 1 bounds every answer to a second; no grace period, each server picks its own delay.
    private let ssdp = SSDPDiscovery(searchTarget: MediaServerDiscovery.searchTarget, maxWait: 1, gracePeriod: nil)
    private let session: URLSession

    init(session: URLSession = HEOSURLSession.localServer) {
        self.session = session
    }

    func discover(timeout: TimeInterval = 1.5) async -> [MediaServerEndpoint] {
        guard let responses = try? await ssdp.search(timeout: timeout) else { return [] }
        return await withTaskGroup(of: MediaServerEndpoint?.self, returning: [MediaServerEndpoint].self) { group in
            for response in responses {
                group.addTask { await describe(response) }
            }
            var endpoints: [MediaServerEndpoint] = []
            for await endpoint in group {
                if let endpoint { endpoints.append(endpoint) }
            }
            return endpoints
        }
    }

    private func describe(_ response: SSDPResponse) async -> MediaServerEndpoint? {
        guard let location = URL(string: response.location),
              let (data, _) = try? await session.data(from: location) else { return nil }
        return MediaServerDescription.parse(String(decoding: data, as: UTF8.self), location: location)
    }
}

enum MediaServerDescription {
    static let contentDirectoryPrefix = "urn:schemas-upnp-org:service:ContentDirectory:"

    static func parse(_ xml: String, location: URL) -> MediaServerEndpoint? {
        let collector = DescriptionCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.parse()

        guard let name = collector.friendlyName,
              let service = collector.services.first(where: { $0.type.hasPrefix(contentDirectoryPrefix) }) else {
            return nil
        }
        let base = collector.urlBase.flatMap { URL(string: $0) } ?? location
        guard let controlURL = URL(string: service.control, relativeTo: base)?.absoluteURL else { return nil }
        return MediaServerEndpoint(friendlyName: name, serviceType: service.type, controlURL: controlURL)
    }
}

/// The first friendlyName is the root device's; embedded devices list theirs later.
private final class DescriptionCollector: NSObject, XMLParserDelegate {
    private(set) var friendlyName: String?
    private(set) var urlBase: String?
    private(set) var services: [(type: String, control: String)] = []

    private var serviceType: String?
    private var controlURL: String?
    private var text: String?

    private static let textElements: Set<String> = ["friendlyName", "URLBase", "serviceType", "controlURL"]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if Self.textElements.contains(elementName) { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        text = nil
        switch elementName {
        case "friendlyName":
            if friendlyName == nil, let value, !value.isEmpty { friendlyName = value }
        case "URLBase":
            if let value, !value.isEmpty { urlBase = value }
        case "serviceType":
            serviceType = value
        case "controlURL":
            controlURL = value
        case "service":
            if let serviceType, let controlURL, !controlURL.isEmpty {
                services.append((serviceType, controlURL))
            }
            serviceType = nil
            controlURL = nil
        default:
            break
        }
    }
}
