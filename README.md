# swift-heos

A Swift library for the HEOS CLI protocol, the TCP interface that Denon and Marantz
devices expose on port 1255 to control HEOS speakers, amplifiers and AV receivers.

It covers the CLI protocol (players, groups, browsing, queue, change events), device
discovery over SSDP and Bonjour, and a UPnP AV client for metadata, seek and transport.
Commands run concurrently and responses are matched to their command by parameters.

No dependencies beyond the Swift standard library and Network.framework.

The library comes from [Neos](https://github.com/gaelsimon/neos-audio), a native macOS
HEOS controller, where it runs daily against real hardware.

## Install

```swift
.package(url: "https://github.com/gaelsimon/swift-heos", from: "0.1.0")
```

```swift
.product(name: "HEOSKit", package: "swift-heos")
```

## Usage

`HEOSService` pushes state into a `StateUpdater` you implement.

`StateUpdater` has no default implementations: an application wants the compiler to point
at a requirement it has not handled. Subclass `MinimalStateUpdater` when you only care
about a few signals.

```swift
import HEOSKit
import NeosDomain

@MainActor
final class MyState: MinimalStateUpdater {
    override func setPlayers(_ players: [Player]) {
        for player in players { print(player.name, player.pid) }
    }

    override func setNowPlaying(_ media: NowPlayingMedia) {
        print(media.artist, "-", media.song)
    }
}

let state = MyState()
let heos = HEOSService(stateUpdater: state)

let devices = try await heos.discoverDevices()
guard let device = devices.first else { return }

// Connecting loads players, groups and sources, and picks a player.
try await heos.connect(host: device.host, port: device.port)

if let pid = state.selectedPlayerID {
    try await heos.play(pid: pid)
}
```

## Status

Version 0.x. The protocol layer is stable and well tested. The public API is not settled
yet:

- `StateUpdater` has around 32 requirements and is shaped by the app it comes from.
  A lighter entry point is planned.
- The `NeosDomain` module name is inherited from Neos and will be renamed before 1.0.

Documentation will come later. For now the tests are a good reference.

## Tests

```
swift test
```

The tests need no hardware, the transport is mocked with captured device responses.
