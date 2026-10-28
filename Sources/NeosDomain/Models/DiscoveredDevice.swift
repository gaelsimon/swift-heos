import Foundation

public struct DiscoveredDevice: Identifiable, Equatable, Hashable, Sendable, Codable {
    public let host: String
    public let port: Int
    public let friendlyName: String
    public let modelName: String
    public let modelNumber: String
    public let serialNumber: String
    public let location: String
    public let firmwareVersion: String
    public let deviceID: String
    public let networkID: String
    /// The stereo or surround seat the device reported over UPnP, when discovery could ask.
    public let pair: PairMembership?

    public var id: String { "\(host):\(port)" }

    public init(
        host: String,
        port: Int = 1255,
        friendlyName: String = "",
        modelName: String = "",
        modelNumber: String = "",
        serialNumber: String = "",
        location: String = "",
        firmwareVersion: String = "",
        deviceID: String = "",
        networkID: String = "",
        pair: PairMembership? = nil
    ) {
        self.host = host
        self.port = port
        self.friendlyName = friendlyName
        self.modelName = modelName
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.location = location
        self.firmwareVersion = firmwareVersion
        self.deviceID = deviceID
        self.networkID = networkID
        self.pair = pair
    }

    public func withPair(_ pair: PairMembership?) -> DiscoveredDevice {
        DiscoveredDevice(
            host: host, port: port, friendlyName: friendlyName, modelName: modelName,
            modelNumber: modelNumber, serialNumber: serialNumber, location: location,
            firmwareVersion: firmwareVersion, deviceID: deviceID, networkID: networkID, pair: pair
        )
    }
}
