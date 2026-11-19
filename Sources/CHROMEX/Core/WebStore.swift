import Foundation

/// Downloads a CRX straight from Google's update endpoint.
///
/// Chrome itself installs from the Web Store through this endpoint; the browser
/// only has to know the 32-character extension id. Doing the transfer natively
/// avoids CORS, which a page in WebKit would otherwise be subject to.
enum ChromeWebStore {
    enum StoreError: Error, LocalizedError {
        case invalidIdentifier
        case downloadFailed(String)
        case emptyArchive

        var errorDescription: String? {
            switch self {
            case .invalidIdentifier:
                return "That is not a Chrome Web Store link or 32-character extension id."
            case .downloadFailed(let reason):
                return "The store download failed: \(reason)"
            case .emptyArchive:
                return "The store returned an empty archive."
            }
        }
    }

    /// Accepts a store URL, a bare id, or a link with the id in a query field.
    static func identifier(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count == 32,
           trimmed.allSatisfy({ $0.isASCII && $0 >= "a" && $0 <= "p" }) {
            return trimmed
        }
        guard let range = trimmed.range(of: "[a-p]{32}", options: .regularExpression) else {
            return nil
        }
        return String(trimmed[range])
    }

    static func download(extensionID: String) async throws -> URL {
        guard identifier(from: extensionID) != nil else { throw StoreError.invalidIdentifier }
        let template = "https://clients2.google.com/service/update2/crx?response=redirect"
            + "&prodversion=131.0&acceptformat=crx2,crx3&x=id%3D\(extensionID)%26uc"
        guard let url = URL(string: template) else { throw StoreError.invalidIdentifier }

        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                         + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StoreError.downloadFailed("HTTP \(http.statusCode)")
        }
        guard !data.isEmpty else { throw StoreError.emptyArchive }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromex-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(extensionID).crx")
        try data.write(to: file, options: .atomic)
        AppLog.write("store download: \(extensionID) (\(data.count) bytes)", tag: "ext")
        return file
    }
}
