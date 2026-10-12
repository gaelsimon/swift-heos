import Foundation

/// Album art per object id in a DIDL-Lite listing, as a ContentDirectory Browse returns it.
enum DIDLArtworkIndex {
    static func parse(_ didl: String) -> [String: String] {
        let collector = ArtworkCollector()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return collector.artwork
    }
}

/// Keeps the first albumArtURI of every container and item, keyed by id.
private final class ArtworkCollector: NSObject, XMLParserDelegate {
    private(set) var artwork: [String: String] = [:]
    private var objectIDs: [String] = []
    private var text: String?

    private static let objects: Set<String> = ["container", "item"]

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let name = Self.localName(elementName)
        if Self.objects.contains(name) {
            objectIDs.append(attributes["id"] ?? "")
        } else if name == "albumArtURI" {
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text?.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = Self.localName(elementName)
        if Self.objects.contains(name) {
            objectIDs.removeLast()
        } else if name == "albumArtURI" {
            let uri = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text = nil
            if let id = objectIDs.last, !id.isEmpty, !uri.isEmpty, artwork[id] == nil {
                artwork[id] = uri
            }
        }
    }
}
