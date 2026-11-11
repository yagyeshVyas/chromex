import XCTest

/// End-to-end tests over the generated extension corpus.
///
/// These run the real import pipeline: ZIP parsing, containment, manifest
/// parsing, compatibility analysis. They do not execute extension JavaScript —
/// that requires a device and is reported as untested.
final class ExtensionFixtureTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    private var zipDirectory: URL {
        repositoryRoot.appendingPathComponent("QA/fixtures/zips")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = zipDirectory.appendingPathComponent("\(name).zip")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("fixture \(name).zip missing; run Scripts/make_fixtures.py")
        }
        return url
    }

    func testExpectedFixturesExist() {
        let expected = [
            "basic-content", "dark-mode", "ad-blocker", "popup", "storage",
            "messaging", "background-mv2", "permission-restricted",
            "unsupported-api", "broad-access", "malformed", "missing-manifest",
            "malicious-traversal"
        ]
        for name in expected {
            let url = zipDirectory.appendingPathComponent("\(name).zip")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name).zip")
        }
    }

    func testBasicContentScriptFixture() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("basic-content"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.sourceKind, .zip)
        XCTAssertEqual(staged.manifest.name, "Basic Content Script")
        XCTAssertEqual(staged.manifest.contentScripts.count, 1)
        XCTAssertEqual(staged.report.verdict, .runs)
    }

    func testDarkModeFixtureDeclaresCSS() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("dark-mode"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.manifest.contentScripts.first?.css, ["dark.css"])
        XCTAssertEqual(staged.report.verdict, .runs)
    }

    func testAdBlockerFixtureReportsUnsupportedDNR() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("ad-blocker"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.report.verdict, .runsWithLimits)
        XCTAssertTrue(staged.report.unsupported.contains("declarativeNetRequest"))
        XCTAssertTrue(staged.report.requiresBroadAccess)
    }

    func testPopupFixture() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("popup"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.manifest.action?.defaultPopup, "popup.html")
        XCTAssertEqual(staged.report.verdict, .runs)
    }

    func testStorageFixture() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("storage"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.manifest.backgroundKind, .serviceWorker)
        XCTAssertEqual(staged.report.verdict, .runs)
    }

    func testMessagingFixture() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("messaging"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.manifest.backgroundScripts, ["sw.js"])
        XCTAssertEqual(staged.report.verdict, .runs)
    }

    func testManifestV2Fixture() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("background-mv2"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.manifest.manifestVersion, 2)
        XCTAssertEqual(staged.manifest.backgroundKind, .scripts)
        XCTAssertEqual(staged.report.verdict, .runs)
    }

    func testPermissionRestrictedFixtureHasOneConsentPattern() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("permission-restricted"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.manifest.requestedHostPatterns, ["https://allowed.example.com/*"])
    }

    func testUnsupportedAPIFixture() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("unsupported-api"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertEqual(staged.report.verdict, .runsWithLimits)
        XCTAssertTrue(staged.report.unsupported.contains("alarms"))
        XCTAssertTrue(staged.report.unsupported.contains("cookies"))
    }

    func testBroaderAccessIsFlagged() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("broad-access"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        XCTAssertTrue(staged.report.requiresBroadAccess)
    }

    func testMalformedManifestIsRejected() {
        XCTAssertThrowsError(try ExtensionPackage.stage(from: try fixture("malformed"))) { error in
            guard let manifestError = error as? ManifestError, manifestError == .notAJSONObject else {
                return XCTFail("expected notAJSONObject, got \(error)")
            }
        }
    }

    func testMissingManifestIsRejected() {
        XCTAssertThrowsError(try ExtensionPackage.stage(from: try fixture("missing-manifest"))) { error in
            XCTAssertEqual(error as? PackageError, .missingManifest)
        }
    }

    func testPathTraversalArchiveIsRejected() {
        XCTAssertThrowsError(try ExtensionPackage.stage(from: try fixture("malicious-traversal"))) { error in
            guard let packageError = error as? PackageError, case .pathTraversal = packageError else {
                return XCTFail("expected pathTraversal, got \(error)")
            }
        }
    }

    func testCRXVersionTwoIsRejected() {
        var crx = Data([0x43, 0x72, 0x32, 0x34])          // "Cr24"
        crx.append(contentsOf: [0x02, 0x00, 0x00, 0x00])   // version 2
        crx.append(contentsOf: [0x08, 0x00, 0x00, 0x00])   // header length 8
        crx.append(Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try CRXContainer.payload(from: crx)) { error in
            XCTAssertEqual(error as? PackageError, .unsupportedCRXVersion(2))
        }
    }

    func testStagingDoesNotWriteOutsideQuarantine() throws {
        let staged = try ExtensionPackage.stage(from: try fixture("basic-content"))
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        let escaped = repositoryRoot.appendingPathComponent("escaped.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.directory.appendingPathComponent("manifest.json").path))
    }
}
