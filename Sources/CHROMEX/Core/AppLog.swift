import Foundation

/// Append-only diagnostic log, written to `Documents/chromex.log`.
///
/// Why a file: iOS gives no console on the device and WebKit exposes no remote
/// inspector to a Windows host, so a browser that fails silently is untestable.
/// Everything the runtime catches — navigation failures, extension page errors,
/// JavaScript exceptions inside extension pages — lands here, and the file is
/// reachable through Files because `UIFileSharingEnabled` is on.
enum AppLog {
    private static let queue = DispatchQueue(label: "app.chromex.log")
    private static let maxBytes = 512 * 1024

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static var fileURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("chromex.log")
    }

    static func write(_ message: String, tag: String = "app") {
        let line = "[\(timestamp())] [\(tag)] \(message)\n"
        guard let data = line.data(using: .utf8), let url = fileURL else { return }
        queue.async {
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > UInt64(maxBytes) {
                // Rotate once: keep the tail, drop the rest, so the file never
                // grows without limit on a device that is never wiped.
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    let tail = String(contents.suffix(maxBytes / 2))
                    try? tail.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    static func read() -> String {
        guard let url = fileURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}
