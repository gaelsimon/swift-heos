import Foundation
import Testing
@testable import HEOSKit
import NeosDomain

@Suite("UPnPZoneControlClient", .serialized)
struct UPnPZoneControlClientTests {

    private static let path = "/upnp/control/AiosServicesDvc/ZoneControl"
    private static let noZone = String(repeating: "0", count: 32)

    private func makeClient() throws -> UPnPZoneControlClient {
        try UPnPZoneControlClient(host: "127.0.0.1", port: 60006, sessionConfiguration: MockURLProtocol.makeConfiguration())
    }

    private func response(action: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
        <s:Body>
        <u:\(action)Response xmlns:u="urn:schemas-denon-com:service:ZoneControl:2">
        \(body)
        </u:\(action)Response>
        </s:Body>
        </s:Envelope>
        """
    }

    private func register(uuid: String, name: String, onSet: (@Sendable (String) -> Void)? = nil) {
        MockURLProtocol.register(pathContaining: Self.path) { request in
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetZoneFriendlyName") {
                return (200, self.response(action: "GetZoneFriendlyName", body: "<ZoneFriendlyName>\(name)</ZoneFriendlyName>"))
            }
            if action.contains("SetZoneFriendlyName") {
                onSet?(String(decoding: request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data(), as: UTF8.self))
                return (200, self.response(action: "SetZoneFriendlyName", body: ""))
            }
            return (200, self.response(action: "GetZoneUUID", body: "<ZoneUUID>\(uuid)</ZoneUUID>"))
        }
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    @Test func readsTheZoneNameOfALeader() async throws {
        register(uuid: "f5d6766fa1a85c5c8400ff9c5df3a4cb", name: "All Rooms")
        let client = try makeClient()
        let name = try await client.zoneName()
        #expect(name == "All Rooms")
        await client.invalidateSession()
    }

    @Test func unescapesTheZoneName() async throws {
        register(uuid: "f5d6766fa1a85c5c8400ff9c5df3a4cb", name: "Den &amp; Bath")
        let client = try makeClient()
        let name = try await client.zoneName()
        #expect(name == "Den & Bath")
        await client.invalidateSession()
    }

    @Test func noZoneIsNil() async throws {
        register(uuid: Self.noZone, name: "unused")
        let client = try makeClient()
        let name = try await client.zoneName()
        #expect(name == nil)
        await client.invalidateSession()
    }

    @Test func setSendsTheZoneUUIDAndTheName() async throws {
        let sent = Captured()
        register(uuid: "abc", name: "") { body in sent.set(body) }
        let client = try makeClient()
        try await client.setZoneName("Upstairs <2>")
        let body = sent.value
        #expect(body.contains("<ZoneUUID>abc</ZoneUUID>"))
        #expect(body.contains("<ZoneFriendlyName>Upstairs &lt;2&gt;</ZoneFriendlyName>"))
        await client.invalidateSession()
    }

    @Test func setFailsOutsideAZone() async throws {
        register(uuid: Self.noZone, name: "")
        let client = try makeClient()
        await #expect(throws: (any Error).self) { try await client.setZoneName("All") }
        await client.invalidateSession()
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""
    var value: String { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}
