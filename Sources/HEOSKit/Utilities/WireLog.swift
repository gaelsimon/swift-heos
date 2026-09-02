import Foundation

/// Raw wire capture: HEOS_WIRE_LOG=1 at launch appends traffic and matching decisions to a
/// timestamped file in Documents. Inert otherwise.
final class WireLog: @unchecked Sendable {
    static let shared = WireLog()
    private let lock = NSLock()
    private let handle: FileHandle?
    private let stamp: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        stamp = formatter
        guard ProcessInfo.processInfo.environment["HEOS_WIRE_LOG"] != nil else {
            handle = nil
            return
        }
        let dir = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("heos-wire-\(Int(Date().timeIntervalSince1970)).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        handle?.write(Data("# HEOS wire capture started \(formatter.string(from: Date())) -> \(url.path)\n".utf8))
    }

    func log(_ line: @autoclosure () -> String) {
        guard let handle else { return }
        var text = line()
        if text.contains("system/sign_in") { text = "-> system/sign_in?<redacted>" }
        lock.lock()
        defer { lock.unlock() }
        handle.write(Data("\(stamp.string(from: Date())) \(text)\n".utf8))
    }
}
