import Foundation
import Testing
@testable import HEOSKit

@Suite("MediaServerDescription")
struct MediaServerDescriptionTests {

    private static let location = URL(string: "http://192.168.8.227:8200/description.xml")!
    private static let contentDirectory = "urn:schemas-upnp-org:service:ContentDirectory:1"

    private func service(type: String, control: String) -> String {
        """
        <service>
        <serviceType>\(type)</serviceType>
        <serviceId>urn:upnp-org:serviceId:X</serviceId>
        <SCPDURL>/scpd.xml</SCPDURL>
        <controlURL>\(control)</controlURL>
        <eventSubURL>/event</eventSubURL>
        </service>
        """
    }

    private func description(name: String? = "Kantele NAS", urlBase: String? = nil, services: [String]) -> String {
        """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
        <specVersion><major>1</major><minor>0</minor></specVersion>
        \(urlBase.map { "<URLBase>\($0)</URLBase>" } ?? "")
        <device>
        <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
        \(name.map { "<friendlyName>\($0)</friendlyName>" } ?? "")
        <UDN>uuid:b30d2f7c</UDN>
        <serviceList>\(services.joined())</serviceList>
        </device>
        </root>
        """
    }

    @Test func resolvesRelativeControlURLAgainstLocation() {
        let xml = description(services: [
            service(type: "urn:schemas-upnp-org:service:ConnectionManager:1", control: "/control/ConnectionManager"),
            service(type: Self.contentDirectory, control: "/control/ContentDirectory"),
        ])
        let endpoint = MediaServerDescription.parse(xml, location: Self.location)
        #expect(endpoint?.friendlyName == "Kantele NAS")
        #expect(endpoint?.serviceType == Self.contentDirectory)
        #expect(endpoint?.controlURL.absoluteString == "http://192.168.8.227:8200/control/ContentDirectory")
    }

    @Test func urlBaseWinsOverLocation() {
        let xml = description(urlBase: "http://192.168.8.227:9791/", services: [
            service(type: Self.contentDirectory, control: "/uuid/upnp.org-ContentDirectory-1/control"),
        ])
        let endpoint = MediaServerDescription.parse(xml, location: Self.location)
        #expect(endpoint?.controlURL.absoluteString == "http://192.168.8.227:9791/uuid/upnp.org-ContentDirectory-1/control")
    }

    @Test func keepsAbsoluteControlURL() {
        let xml = description(services: [
            service(type: Self.contentDirectory, control: "http://10.0.0.5:50001/ContentDirectory/control"),
        ])
        let endpoint = MediaServerDescription.parse(xml, location: Self.location)
        #expect(endpoint?.controlURL.absoluteString == "http://10.0.0.5:50001/ContentDirectory/control")
    }

    @Test func acceptsLaterContentDirectoryVersions() {
        let type = "urn:schemas-upnp-org:service:ContentDirectory:3"
        let xml = description(services: [service(type: type, control: "/cd")])
        let endpoint = MediaServerDescription.parse(xml, location: Self.location)
        #expect(endpoint?.serviceType == type)
    }

    @Test func rejectsDeviceWithoutContentDirectory() {
        let xml = description(services: [
            service(type: "urn:schemas-upnp-org:service:AVTransport:1", control: "/avt"),
        ])
        #expect(MediaServerDescription.parse(xml, location: Self.location) == nil)
    }

    @Test func rejectsDeviceWithoutFriendlyName() {
        let xml = description(name: nil, services: [service(type: Self.contentDirectory, control: "/cd")])
        #expect(MediaServerDescription.parse(xml, location: Self.location) == nil)
    }

    @Test func rootDeviceNameWinsOverEmbeddedDevice() {
        let xml = """
        <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
        <friendlyName>NASPERES</friendlyName>
        <deviceList><device><friendlyName>Embedded</friendlyName>
        <serviceList>\(service(type: Self.contentDirectory, control: "/ContentDirectory/control"))</serviceList>
        </device></deviceList>
        </device></root>
        """
        let endpoint = MediaServerDescription.parse(xml, location: Self.location)
        #expect(endpoint?.friendlyName == "NASPERES")
        #expect(endpoint?.controlURL.path == "/ContentDirectory/control")
    }

    @Test func trimsWhitespaceAroundValues() {
        let xml = description(name: "\n  Minim Nasperes \n", services: [
            service(type: Self.contentDirectory, control: "\n /cd \n"),
        ])
        let endpoint = MediaServerDescription.parse(xml, location: Self.location)
        #expect(endpoint?.friendlyName == "Minim Nasperes")
        #expect(endpoint?.controlURL.path == "/cd")
    }
}
