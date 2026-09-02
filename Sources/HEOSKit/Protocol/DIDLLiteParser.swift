import Foundation

/// Parses UPnP DIDL-Lite XML (from AVTransport metadata) into `TrackMetadata`.
public enum DIDLLiteParser {

    /// Parse a raw metadata string (potentially XML-entity-escaped) into `TrackMetadata`.
    /// Returns nil if the string is nil, empty, or unparseable.
    public static func parse(_ rawMetadata: String?) -> TrackMetadata? {
        guard let raw = rawMetadata, !raw.isEmpty else { return nil }

        // The SOAP response may return DIDL-Lite with XML entities escaped.
        // Unescape before parsing as XML.
        let xml = unescapeXMLEntities(raw)

        guard let item = ItemCollector.collect(from: xml) else { return nil }

        let genre = usableText(item.values["genre"])
        let trackNumber = usableText(item.values["originalTrackNumber"]).flatMap(Int.init)
        let albumArtURI = usableText(item.values["albumArtURI"])

        let sampleRate = item.resAttributes["sampleFrequency"].flatMap(Int.init)
        let bitDepth = item.resAttributes["bitsPerSample"].flatMap(Int.init)
        let channels = item.resAttributes["nrAudioChannels"].flatMap(Int.init)
        let bitrate = item.resAttributes["bitrate"].flatMap(Int.init)

        // Codec: try protocolInfo MIME type first, then Denon-specific audioFormat descriptor
        let codec = item.resAttributes["protocolInfo"].flatMap(Self.codecFromProtocolInfo)
            ?? usableText(item.audioFormat)?.uppercased()

        let metadata = TrackMetadata(
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            bitrate: bitrate,
            codec: codec,
            genre: genre,
            trackNumber: trackNumber,
            albumArtURI: albumArtURI
        )

        // Return nil if every field is nil (nothing useful was parsed)
        if metadata == TrackMetadata() {
            return nil
        }
        return metadata
    }

    // MARK: - Private Helpers

    /// Trims a captured value, rejecting blanks and Denon's literal `""` placeholder.
    private static func usableText(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != "\"\"" else { return nil }
        return text
    }

    /// Derive a display codec name from the UPnP protocolInfo string.
    /// Format: "transport:*:mime-type:*" e.g. "http-get:*:audio/flac:*"
    static func codecFromProtocolInfo(_ protocolInfo: String) -> String? {
        let parts = protocolInfo.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        let mime = String(parts[2]).trimmingCharacters(in: .whitespaces).lowercased()
        // Wildcard MIME type (e.g. "http-get:*:*:DLNA...") means no codec info
        if mime == "*" { return nil }
        return mimeToCodec[mime]
    }

    private static let mimeToCodec: [String: String] = [
        "audio/flac": "FLAC",
        "audio/x-flac": "FLAC",
        "audio/mp4": "AAC",
        "audio/x-m4a": "AAC",
        "audio/aac": "AAC",
        "audio/aacp": "AAC",
        "audio/mpeg": "MP3",
        "audio/mp3": "MP3",
        "audio/x-wav": "WAV",
        "audio/wav": "WAV",
        "audio/L16": "PCM",
        "audio/ogg": "OGG",
        "audio/x-ms-wma": "WMA",
        "audio/aiff": "AIFF",
        "audio/x-aiff": "AIFF",
        "audio/dsf": "DSD",
        "audio/x-dsd": "DSD",
    ]

    /// Unescape XML entities that may be present in SOAP-embedded DIDL-Lite.
    private static func unescapeXMLEntities(_ string: String) -> String {
        // If it already looks like XML (starts with <), no unescaping needed
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            return string
        }

        return SOAPEnvelope.unescapeXMLEntities(string)
    }
}

// MARK: - Item Collection

/// Reads the first `<item>` with `XMLParser`, matching local names as the `local-name()` XPath
/// predicates it replaces did -- `XMLDocument` and XPath are macOS-only.
private final class ItemCollector: NSObject, XMLParserDelegate {
    /// Text of the first `genre`, `originalTrackNumber` and `albumArtURI` child, untrimmed.
    private(set) var values: [String: String] = [:]
    /// Attributes of the first `res` child.
    private(set) var resAttributes: [String: String] = [:]
    /// Text of the first `<desc id="audioFormat">` child, untrimmed.
    private(set) var audioFormat: String?

    private static let textElements: Set<String> = ["genre", "originalTrackNumber", "albumArtURI"]

    private var depth = 0
    private var itemDepth: Int?
    private var sawRes = false
    private var itemClosed = false
    private var capturing: String?
    private var text = ""
    private var sawAudioFormat = false

    /// Returns nil only when no `item` was reached. A document that breaks later still yields
    /// what came before: devices send a stray control character in an artist name often enough,
    /// and SAX reports each element as it reads it, so the fields already in hand are sound.
    /// `XMLDocument` could not do this -- it rejected the whole document.
    static func collect(from xml: String) -> ItemCollector? {
        let collector = ItemCollector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        // Never fetch external entities: this XML comes off the network (XXE).
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        guard collector.itemDepth != nil else { return nil }
        if !parsed {
            HEOSLogger.upnp.debug("DIDL-Lite broke mid-document; keeping the fields read before it")
        }
        return collector
    }

    /// Strips a namespace prefix: `upnp:genre` -> `genre`.
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
        depth += 1
        guard !itemClosed else { return }
        let name = Self.localName(elementName)

        guard let itemDepth else {
            if name == "item" { self.itemDepth = depth }
            return
        }
        // Only direct children describe the item; nested markup is not addressed by the predicates.
        guard depth == itemDepth + 1 else { return }

        switch name {
        case "res":
            // First res wins attributes or not, as XPath's `.first` did; a later
            // rendition never replaces it.
            guard !sawRes else { return }
            sawRes = true
            resAttributes = attributes
        case "desc":
            // First audioFormat descriptor wins, empty text included: it means "no codec".
            guard !sawAudioFormat, attributes["id"] == "audioFormat" else { return }
            sawAudioFormat = true
            beginCapturing(name)
        case _ where Self.textElements.contains(name):
            guard values[name] == nil else { return }
            beginCapturing(name)
        default:
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing != nil else { return }
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let name = Self.localName(elementName)
        if let capturing, name == capturing, depth == (itemDepth ?? 0) + 1 {
            if capturing == "desc" {
                audioFormat = text
            } else {
                values[capturing] = text
            }
            self.capturing = nil
        }
        if let itemDepth, depth == itemDepth, name == "item" { itemClosed = true }
        depth -= 1
    }

    private func beginCapturing(_ name: String) {
        capturing = name
        text = ""
    }
}
