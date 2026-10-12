import Foundation

/// A clock the test moves by hand, so time-based windows cost no waiting.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    var instant: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return base.advanced(by: offset)
    }

    func advance(by amount: Duration) {
        lock.lock()
        defer { lock.unlock() }
        offset += amount
    }
}

/// A thread-safe call counter for closures handed to the code under test.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

extension URLRequest {
    /// The body URLSession hands a URLProtocol as a stream rather than data.
    var bodyString: String {
        if let httpBody { return String(decoding: httpBody, as: UTF8.self) }
        guard let stream = httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
