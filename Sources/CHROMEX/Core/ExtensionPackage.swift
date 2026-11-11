import Compression
import Foundation

// MARK: - Errors

enum PackageError: Error, LocalizedError, Equatable {
    case emptyFile
    case notAZipArchive
    case unsupportedCompression(Int)
    case encryptedEntry
    case pathTraversal(String)
    case absolutePath(String)
    case pathTooDeep(String)
    case entryNameTooLong(String)
    case tooManyEntries(Int)
    case entryTooLarge(String)
    case archiveTooLarge
    case compressionRatioExceeded(String)
    case decompressionFailed(String)
    case missingManifest
    case invalidCRXMagic
    case unsupportedCRXVersion(Int)
    case invalidCRXHeader
    case missingPayload

    var errorDescription: String? {
        switch self {
        case .emptyFile: return "The file is empty."
        case .notAZipArchive: return "This is not a valid ZIP archive."
        case .unsupportedCompression(let method): return "Unsupported ZIP compression method \(method). Only stored and deflate are supported."
        case .encryptedEntry: return "Encrypted ZIP entries are not supported."
        case .pathTraversal(let path): return "The archive contains an unsafe path: \(path)"
        case .absolutePath(let path): return "The archive contains an absolute path: \(path)"
        case .pathTooDeep(let path): return "The archive path is nested too deeply: \(path)"
        case .entryNameTooLong(let path): return "The archive contains an over-long file name: \(path)"
        case .tooManyEntries(let count): return "The archive contains \(count) entries, which exceeds the limit."
        case .entryTooLarge(let path): return "The archive entry is too large: \(path)"
        case .archiveTooLarge: return "The archive expands beyond the allowed size."
        case .compressionRatioExceeded(let path): return "The archive entry expands suspiciously: \(path)"
        case .decompressionFailed(let path): return "Could not decompress \(path)."
        case .missingManifest: return "The package has no manifest.json at its root."
        case .invalidCRXMagic: return "This is not a CRX file (missing Cr24 header)."
        case .unsupportedCRXVersion(let version): return "CRX version \(version) is not supported. CHROMEX reads CRX3 only."
        case .invalidCRXHeader: return "The CRX header is malformed."
        case .missingPayload: return "The CRX file has no ZIP payload."
        }
    }
}

// MARK: - Limits

struct PackageLimits: Sendable {
    var maxEntries: Int = 5_000
    var maxTotalUncompressed: Int = 100 * 1_024 * 1_024
    var maxEntryUncompressed: Int = 50 * 1_024 * 1_024
    var maxCompressionRatio: Int = 100
    var maxPathDepth: Int = 16
    var maxNameLength: Int = 255

    static let `default` = PackageLimits()
}

// MARK: - ZIP

enum ZipReader {
    struct Entry: Sendable {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
        var flags: UInt16
    }

    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let localSignature: UInt32 = 0x0403_4b50

    /// Reads the central directory. Throws on structural problems, not on policy —
    /// policy lives in `extract`.
    static func entries(in data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw PackageError.notAZipArchive }
        guard let eocd = findEOCD(bytes) else { throw PackageError.notAZipArchive }

        let entryCount = Int(readUInt16(bytes, eocd + 10))
        let directoryOffset = Int(readUInt32(bytes, eocd + 16))
        guard directoryOffset > 0, directoryOffset < bytes.count else { throw PackageError.notAZipArchive }

        var entries: [Entry] = []
        entries.reserveCapacity(min(entryCount, 1_024))
        var cursor = directoryOffset

        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, readUInt32(bytes, cursor) == centralSignature else {
                throw PackageError.notAZipArchive
            }
            let flags = readUInt16(bytes, cursor + 8)
            let method = readUInt16(bytes, cursor + 10)
            let compressed = Int(readUInt32(bytes, cursor + 20))
            let uncompressed = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))

            guard cursor + 46 + nameLength <= bytes.count else { throw PackageError.notAZipArchive }
            let nameStart = cursor + 46
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw PackageError.notAZipArchive
            }

            entries.append(Entry(
                name: name,
                method: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                flags: flags
            ))

            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Extracts an archive into `root`, enforcing containment and size policy.
    /// Returns the list of files written, relative to `root`.
    @discardableResult
    static func extract(data: Data, to root: URL, limits: PackageLimits = .default) throws -> [String] {
        guard !data.isEmpty else { throw PackageError.emptyFile }
        let entries = try entries(in: data)
        guard entries.count <= limits.maxEntries else { throw PackageError.tooManyEntries(entries.count) }

        let bytes = [UInt8](data)
        let canonicalRoot = root.standardizedFileURL.path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var totalUncompressed = 0
        var written: [String] = []

        for entry in entries {
            if entry.flags & 0x1 != 0 { throw PackageError.encryptedEntry }
            if entry.name.hasSuffix("/") { continue }

            let safeName = try sanitize(entry.name, limits: limits)
            guard entry.uncompressedSize <= limits.maxEntryUncompressed else {
                throw PackageError.entryTooLarge(safeName)
            }
            totalUncompressed += entry.uncompressedSize
            guard totalUncompressed <= limits.maxTotalUncompressed else {
                throw PackageError.archiveTooLarge
            }
            if entry.compressedSize > 0 && entry.uncompressedSize > 0 {
                let ratio = entry.uncompressedSize / max(entry.compressedSize, 1)
                guard ratio <= limits.maxCompressionRatio else {
                    throw PackageError.compressionRatioExceeded(safeName)
                }
            }

            let payload = try payloadBytes(for: entry, in: bytes)
            let output: Data
            switch entry.method {
            case 0:
                output = payload
            case 8:
                output = try inflate(payload, expectedSize: entry.uncompressedSize, name: safeName)
            default:
                throw PackageError.unsupportedCompression(Int(entry.method))
            }

            let destination = root.appendingPathComponent(safeName).standardizedFileURL
            let destinationPath = destination.path
            // Belt and braces: the resolved path must stay inside the extraction root.
            guard destinationPath == canonicalRoot || destinationPath.hasPrefix(canonicalRoot + "/") else {
                throw PackageError.pathTraversal(safeName)
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try output.write(to: destination, options: .atomic)
            written.append(safeName)
        }
        return written
    }

    static func sanitize(_ rawName: String, limits: PackageLimits = .default) throws -> String {
        let normalised = rawName.replacingOccurrences(of: "\\", with: "/")
        guard !normalised.hasPrefix("/") else { throw PackageError.absolutePath(rawName) }
        guard !normalised.contains("\0") else { throw PackageError.pathTraversal(rawName) }
        guard normalised.utf8.count <= limits.maxNameLength else {
            throw PackageError.entryNameTooLong(rawName)
        }
        let components = normalised.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains("..") else { throw PackageError.pathTraversal(rawName) }
        guard components.count <= limits.maxPathDepth else { throw PackageError.pathTooDeep(rawName) }
        return components.joined(separator: "/")
    }

    private static func payloadBytes(for entry: Entry, in bytes: [UInt8]) throws -> Data {
        let local = entry.localHeaderOffset
        guard local + 30 <= bytes.count, readUInt32(bytes, local) == localSignature else {
            throw PackageError.notAZipArchive
        }
        let nameLength = Int(readUInt16(bytes, local + 26))
        let extraLength = Int(readUInt16(bytes, local + 28))
        let start = local + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count, start <= end else { throw PackageError.notAZipArchive }
        return Data(bytes[start..<end])
    }

    private static func inflate(_ source: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return source.withUnsafeBytes { sourceBuffer -> Int in
                guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw PackageError.decompressionFailed(name) }
        return output
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowerBound = max(0, bytes.count - 65_557)
        var index = bytes.count - 22
        while index >= lowerBound {
            if readUInt32(bytes, index) == eocdSignature {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

// MARK: - CRX

enum CRXContainer {
    /// Extracts the ZIP payload from a CRX3 container.
    ///
    /// This validates the container's structure — magic, version, header length —
    /// but does **not** verify the signature. CHROMEX has no trust anchor for a
    /// developer's key, so a signature check would prove only internal
    /// consistency. The UI says exactly that.
    static func payload(from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw PackageError.emptyFile }
        guard bytes[0] == 0x43, bytes[1] == 0x72, bytes[2] == 0x32, bytes[3] == 0x34 else {
            throw PackageError.invalidCRXMagic
        }
        let version = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)
        guard version == 3 else { throw PackageError.unsupportedCRXVersion(Int(version)) }
        let headerLength = Int(UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24))
        guard headerLength > 0, headerLength <= 64 * 1_024 else { throw PackageError.invalidCRXHeader }
        let payloadStart = 12 + headerLength
        guard payloadStart < bytes.count else { throw PackageError.missingPayload }
        return Data(bytes[payloadStart..<bytes.count])
    }
}

// MARK: - Package inspection

enum PackageSourceKind: String, Codable, Sendable {
    case folder
    case zip
    case crx
}

struct StagedPackage: Sendable {
    var sourceKind: PackageSourceKind
    var manifest: ExtensionManifest
    var report: CompatibilityReport
    var directory: URL
    var signatureVerified: Bool
}

enum ExtensionPackage {
    /// Copies/stages a user-selected package into a fresh temporary directory and
    /// analyses it. Never writes outside the temporary directory.
    static func stage(from url: URL, limits: PackageLimits = .default) throws -> StagedPackage {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("chromex-import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        var kind: PackageSourceKind
        var signatureVerified = false

        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            kind = .folder
            try copyDirectory(from: url, to: staging)
        } else {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            if ext == "crx" {
                kind = .crx
                let payload = try CRXContainer.payload(from: data)
                try ZipReader.extract(data: payload, to: staging, limits: limits)
                signatureVerified = false
            } else {
                kind = .zip
                try ZipReader.extract(data: data, to: staging, limits: limits)
            }
        }

        guard let manifestData = readManifest(in: staging) else { throw PackageError.missingManifest }
        let manifest = try ManifestParser.parse(data: manifestData)
        let report = CompatibilityAnalyzer.analyze(manifest)

        return StagedPackage(
            sourceKind: kind,
            manifest: manifest,
            report: report,
            directory: staging,
            signatureVerified: signatureVerified
        )
    }

    static func readManifest(in directory: URL) -> Data? {
        let direct = directory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: direct) { return data }
        // Tolerate a single wrapper directory, which is common in GitHub ZIPs.
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let directories = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard directories.count == 1, let only = directories.first else { return nil }
        return try? Data(contentsOf: only.appendingPathComponent("manifest.json"))
    }

    private static func copyDirectory(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let contents = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for item in contents {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            try manager.copyItem(at: item, to: target)
        }
    }
}
