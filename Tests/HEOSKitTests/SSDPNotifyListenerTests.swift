import Testing
import Foundation
import Darwin
@testable import HEOSKit

@Suite("SSDP NOTIFY Listener Tests")
struct SSDPNotifyListenerTests {

    @Test func stopEndsTheStreamEvenWhenTheSocketNumberIsReused() async throws {
        let listener = SSDPNotifyListener()
        let stream = await listener.listen()
        let socketFD = try #require(Self.descriptorBound(toPort: 1900))
        let path = NSTemporaryDirectory() + UUID().uuidString
        let file = open(path, O_RDWR | O_CREAT, 0o600)
        defer {
            close(file)
            unlink(path)
        }

        await listener.stop()
        dup2(file, socketFD)

        #expect(await Self.finishes(stream, within: .seconds(2)))
    }

    private static func descriptorBound(toPort port: UInt16) -> Int32? {
        (0..<getdtablesize()).first { fd in
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return result == 0 && address.sin_family == sa_family_t(AF_INET) && UInt16(bigEndian: address.sin_port) == port
        }
    }

    private static func finishes(_ stream: AsyncStream<SSDPResponse>, within limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return !Task.isCancelled
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }
}
