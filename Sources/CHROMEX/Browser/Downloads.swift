import Foundation
import UIKit
import WebKit

/// Owns every in-flight `WKDownload` and the blob/data transfers that WebKit
/// cannot hand to a download delegate.
///
/// WebKit downloads and URLSession downloads share one list in `AppModel`, so the
/// Downloads screen shows a single history regardless of which path produced the
/// file.
@MainActor
final class DownloadCenter: NSObject, @preconcurrency WKDownloadDelegate {
    private weak var model: AppModel?
    private var itemIDs: [ObjectIdentifier: UUID] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var progressObjects: [ObjectIdentifier: Progress] = [:]
    private var progressObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    // MARK: Starts

    /// Adopts a download WebKit has already begun after a `.download` policy.
    @discardableResult
    func adopt(_ download: WKDownload, suggestedName: String? = nil) -> UUID {
        let source = download.originalRequest?.url?.absoluteString ?? ""
        let filename = Self.safeFilename(suggestedName ?? download.originalRequest?.url?.lastPathComponent ?? "download")
        let item = DownloadItem(filename: filename, sourceURLString: source, state: .inProgress)
        model?.insertDownload(item)
        itemIDs[ObjectIdentifier(download)] = item.id
        download.delegate = self
        let progress = download.progress
        progressObjects[ObjectIdentifier(download)] = progress
        progressObservers[ObjectIdentifier(download)] = progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { [weak self, weak download] _, change in
            guard let fraction = change.newValue else { return }
            Task { @MainActor [weak self, weak download] in
                guard let self, let download, let id = self.itemIDs[ObjectIdentifier(download)] else { return }
                self.model?.updateDownload(id: id, progress: fraction)
            }
        }
        AppLog.write("download started: \(source)", tag: "download")
        return item.id
    }

    /// Handles `blob:` navigations. WebKit cannot download a blob URL itself, so the
    /// page fetches it and posts a base64 data URL to the native bridge.
    func saveDataURL(_ dataURL: String, suggestedName: String?, mimeType: String?) {
        guard let comma = dataURL.firstIndex(of: ",") else { return }
        let header = String(dataURL[dataURL.startIndex..<comma])
        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard header.contains("base64"), let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
            AppLog.write("blob download rejected: unsupported data URL", tag: "download")
            return
        }

        var filename = Self.safeFilename(suggestedName ?? "download")
        if URL(fileURLWithPath: filename).pathExtension.isEmpty, let mimeType {
            filename += Self.fileExtension(for: mimeType)
        }

        let item = DownloadItem(filename: filename, sourceURLString: "blob", state: .inProgress)
        model?.insertDownload(item)

        guard let destination = Self.uniqueDestination(filename: filename) else {
            model?.failDownload(id: item.id, message: "Could not create the Downloads folder.")
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
            model?.completeDownload(id: item.id, path: destination.path, byteCount: Int64(data.count))
            AppLog.write("blob saved: \(destination.lastPathComponent) (\(data.count) bytes)", tag: "download")
        } catch {
            model?.failDownload(id: item.id, message: error.localizedDescription)
        }
    }

    // MARK: WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let destination = Self.uniqueDestination(filename: Self.safeFilename(suggestedFilename)) else {
            return nil
        }
        if let id = itemIDs[ObjectIdentifier(download)] {
            destinations[ObjectIdentifier(download)] = destination
            model?.renameDownload(id: id, filename: destination.lastPathComponent)
        }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let id = itemIDs.removeValue(forKey: key) else { return }
        let destination = destinations.removeValue(forKey: key)
        progressObservers[key]?.invalidate()
        progressObservers[key] = nil
        progressObjects[key] = nil
        let path = destination?.path
        model?.completeDownload(id: id, path: path, byteCount: Self.byteCount(of: path))
        AppLog.write("download finished: \(path ?? "unknown")", tag: "download")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let id = itemIDs.removeValue(forKey: key) else { return }
        progressObservers[key]?.invalidate()
        progressObservers[key] = nil
        progressObjects[key] = nil
        model?.failDownload(id: id, message: error.localizedDescription)
        AppLog.write("download failed: \(error.localizedDescription)", tag: "download")
    }

    // MARK: Helpers

    private static func byteCount(of path: String?) -> Int64 {
        guard let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func downloadsDirectory() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func uniqueDestination(filename: String) -> URL? {
        guard let directory = downloadsDirectory() else { return nil }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var index = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    static func safeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return cleaned.isEmpty ? "download" : String(cleaned.prefix(180))
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return ".png"
        case "image/jpeg": return ".jpg"
        case "image/webp": return ".webp"
        case "image/gif": return ".gif"
        case "application/pdf": return ".pdf"
        case "text/plain": return ".txt"
        case "text/html": return ".html"
        case "application/json": return ".json"
        case "application/zip": return ".zip"
        case "video/mp4": return ".mp4"
        case "audio/mpeg": return ".mp3"
        default: return ".bin"
        }
    }
}

// MARK: - Printing

@MainActor
enum PagePrinter {
    static func print(webView: WKWebView, in viewController: UIViewController?) {
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        controller.printInfo = {
            let info = UIPrintInfo.printInfo()
            info.jobName = webView.title ?? webView.url?.host ?? "CHROMEX"
            info.outputType = .general
            return info
        }()
        guard let target = viewController ?? topViewController() else { return }
        controller.present(from: target.view.bounds, in: target.view, animated: true, completionHandler: nil)
    }

    private static func topViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
