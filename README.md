# swift-heos

A Swift library for the **HEOS CLI protocol** — the TCP interface Denon and Marantz
expose on port 1255 for controlling HEOS-enabled speakers, amplifiers and AV receivers.

Zero dependencies beyond the Swift standard library and `Network.framework`. 454 tests.

MIT licensed. Extracted from [Neos](https://github.com/gaelsimon/neos-audio), a native
macOS HEOS controller, where it has been in daily use against real hardware.

## Why this exists

`pyheos` is the reference implementation of the HEOS CLI protocol, and it is excellent.
There was no Swift equivalent. This is that, plus three things no HEOS library
currently offers:

| | swift-heos | pyheos | heos-api (TS) |
|---|---|---|---|
| CLI protocol | ✅ | ✅ | thin wrapper |
| Groups (leader / member) | ✅ | ✅ | ❌ |
| **Stereo pair vs multi-room** | ✅ | ❌ | ❌ |
| **Device discovery** | ✅ SSDP + Bonjour | ❌ | SSDP |
| **UPnP AV** (metadata, seek, transport) | ✅ | ❌ | ❌ |
| Concurrent commands | ✅ | serialised | ✅ |

### Stereo pairs

HEOS reports a configured stereo pair as a *group*, named after its leader. A pair of
speakers called "Kitchen Left" and "Kitchen Right" therefore shows up as a group named
"Kitchen Left", indistinguishable from a two-room group — which is how every other
client displays it.

This library separates the two. A group whose name differs from its leader's
(`"Back Patio + Front Porch"`) is treated as multi-room; a group named after its leader is a
*candidate* pair, confirmed by reading each member's UPnP channel assignment, and named from
what the members share: `"Kitchen"`. The naming half of that rule is a heuristic validated
against one hardware setup — see [Inferred, not confirmed](#inferred-not-confirmed).

### Concurrency

`pyheos` holds a lock and keeps one command in flight, which sidesteps response
matching entirely. This library issues commands concurrently and matches responses
FIFO per command key, so a six-query player refresh costs one round trip instead of six.

## Install

```swift
.package(url: "https://github.com/gaelsimon/swift-heos", from: "0.1.0")
```

```swift
.product(name: "HEOSKit", package: "swift-heos")
```

## Usage

`HEOSService` pushes state into a `StateUpdater` you implement, rather than returning it.

`StateUpdater` has no default implementations on purpose: an application wants the compiler
to name a requirement it has not handled. Subclass `MinimalStateUpdater` when you only care
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

## Protocol notes

Denon publishes the CLI specification as a PDF, in several versions across several
hosts. It documents the commands; it does not document the behaviour. What this library
had to learn the hard way:

- **`command under process`** is not a response. It means "still working" and resets the
  timeout — a client that treats it as a result will re-ask a device that is already busy.
- **Positions and durations are milliseconds**, not seconds.
- **`now_playing_changed` fires before the metadata is populated.** A non-zero `duration`
  is a cheaper readiness signal than a timer; a waking amplifier can take 20 seconds.
- **Response matching by command path alone is ambiguous.** Two concurrent
  `player/get_queue` for different ranges share a key and can be resolved with each
  other's payload. Keys need the discriminating parameters.
- **Bonjour results carry no serial number**, so a pair learned over Bonjour has to be
  cached by name as well as by serial.
- **A group fetch that fails is not an empty group list.** Publishing `[]` on a timeout
  drops every group from the UI until the next `groups_changed`.

### Inferred, not confirmed

Held to a lower standard than the notes above, and stated here so nobody builds on it
without knowing:

- **A group named after its leader may indicate a stereo pair**, where a multi-room group
  appears to be named `"Leader + Member"`. The evidence is one multi-room example in
  `pyheos`'s test fixtures and one report of a pair displaying as `"Kitchen Left"`. It is
  the heuristic this library uses, confirmed against a single hardware configuration.
  **Counter-examples are the most useful thing you can send.**

## Status

`0.x`. The protocol layer is stable and covered; the integration surface is not settled:

- `StateUpdater` has ~32 requirements and is shaped by the app it came from. A lighter
  entry point — an `AsyncSequence` of state changes — is the intended direction.
- The `NeosDomain` module name is inherited and will be renamed before `1.0`.
- Stereo pair classification is validated against one hardware configuration. **Reports
  from other setups are the single most useful contribution right now** — see
  [issues](https://github.com/gaelsimon/swift-heos/issues).

## Tests

```
swift test
```

454 tests, no hardware required — the transport is mocked from captured device responses.
