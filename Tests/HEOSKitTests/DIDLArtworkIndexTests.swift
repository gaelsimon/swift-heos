import Testing
@testable import HEOSKit

@Suite("DIDLArtworkIndex")
struct DIDLArtworkIndexTests {

    private static let header = """
    <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
    xmlns:dc="http://purl.org/dc/elements/1.1/" \
    xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
    xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">
    """

    @Test func mapsContainersAndItemsByID() {
        let didl = Self.header + """
        <container id="al-1" parentID="albums" restricted="1">
        <dc:title>One</dc:title>
        <upnp:albumArtURI dlna:profileID="JPEG_SM">http://nas:8200/art/al-1</upnp:albumArtURI>
        <upnp:class>object.container.album.musicAlbum</upnp:class>
        </container>
        <item id="tr-9" parentID="al-1" restricted="1">
        <upnp:albumArtURI>http://nas:8200/art/tr-9</upnp:albumArtURI>
        </item>
        </DIDL-Lite>
        """
        let artwork = DIDLArtworkIndex.parse(didl)
        #expect(artwork == ["al-1": "http://nas:8200/art/al-1", "tr-9": "http://nas:8200/art/tr-9"])
    }

    @Test func keepsFirstArtOfAnObject() {
        let didl = Self.header + """
        <container id="0$albums$*a0">
        <upnp:albumArtURI>http://nas/first.jpg</upnp:albumArtURI>
        <upnp:albumArtURI>http://nas/second.jpg</upnp:albumArtURI>
        </container></DIDL-Lite>
        """
        #expect(DIDLArtworkIndex.parse(didl) == ["0$albums$*a0": "http://nas/first.jpg"])
    }

    @Test func skipsObjectsWithoutArtOrID() {
        let didl = Self.header + """
        <container id="bare"><dc:title>No art</dc:title></container>
        <container><upnp:albumArtURI>http://nas/anon.jpg</upnp:albumArtURI></container>
        <container id="blank"><upnp:albumArtURI>  </upnp:albumArtURI></container>
        </DIDL-Lite>
        """
        #expect(DIDLArtworkIndex.parse(didl).isEmpty)
    }

    @Test func decodesEntitiesInURI() {
        let didl = Self.header + """
        <item id="t"><upnp:albumArtURI>http://nas/art?a=1&amp;b=2</upnp:albumArtURI></item></DIDL-Lite>
        """
        #expect(DIDLArtworkIndex.parse(didl) == ["t": "http://nas/art?a=1&b=2"])
    }

    @Test func acceptsUnprefixedAlbumArtURI() {
        let didl = "<DIDL-Lite><container id=\"c\"><albumArtURI>http://nas/c.jpg</albumArtURI></container></DIDL-Lite>"
        #expect(DIDLArtworkIndex.parse(didl) == ["c": "http://nas/c.jpg"])
    }

    @Test func keepsWhatCameBeforeABrokenDocument() {
        let didl = Self.header + """
        <container id="ok"><upnp:albumArtURI>http://nas/ok.jpg</upnp:albumArtURI></container>
        <container id="bad"><dc:title>\u{01}</dc:title>
        """
        #expect(DIDLArtworkIndex.parse(didl)["ok"] == "http://nas/ok.jpg")
    }

    @Test func emptyDocumentHasNoArt() {
        #expect(DIDLArtworkIndex.parse("").isEmpty)
    }
}
