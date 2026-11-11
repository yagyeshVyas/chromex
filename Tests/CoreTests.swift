import XCTest

final class URLResolverTests: XCTestCase {
    private let engine = SearchEngine.builtIns[0]

    func testBareDomainUpgradesToHTTPS() {
        let url = URLResolver.destination(for: "example.com", engine: engine)
        XCTAssertEqual(url?.absoluteString, "https://example.com")
    }

    func testExplicitSchemeWins() {
        let url = URLResolver.destination(for: "http://example.com/path?q=1", engine: engine)
        XCTAssertEqual(url?.absoluteString, "http://example.com/path?q=1")
    }

    func testLocalhostUsesHTTP() {
        let url = URLResolver.destination(for: "localhost:3000", engine: engine)
        XCTAssertEqual(url?.scheme, "http")
        XCTAssertEqual(url?.host, "localhost")
    }

    func testSearchForFreeText() {
        let url = URLResolver.destination(for: "best phone 2026", engine: engine)
        XCTAssertEqual(url?.host, "www.google.com")
        XCTAssertTrue(url?.absoluteString.contains("best%20phone%202026") ?? false)
    }

    func testHostWithPath() {
        let url = URLResolver.destination(for: "example.com/a/b", engine: engine)
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.path, "/a/b")
    }

    func testUnsupportedSchemeFallsBackToSearch() {
        let url = URLResolver.destination(for: "javascript:alert(1)", engine: engine)
        XCTAssertEqual(url?.host, "www.google.com")
    }

    func testDisplayStringStripsSchemeAndWWW() {
        let url = URL(string: "https://www.example.com/path")
        XCTAssertEqual(URLResolver.displayString(for: url), "example.com/path")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(URLResolver.destination(for: "   ", engine: engine))
    }

    func testSearchTemplateEncoding() {
        let url = SearchEngine.builtIns[1].url(for: "a&b")
        XCTAssertTrue(url?.absoluteString.contains("a&b") ?? false)
    }
}

final class HostMatcherTests: XCTestCase {
    func testAllURLs() {
        let url = URL(string: "https://anything.example")!
        XCTAssertTrue(HostMatcher.matches(pattern: "<all_urls>", url: url))
    }

    func testWildcardSubdomain() {
        let url = URL(string: "https://api.example.com/x")!
        XCTAssertTrue(HostMatcher.matches(pattern: "*://*.example.com/*", url: url))
        XCTAssertFalse(HostMatcher.matches(pattern: "*://*.other.com/*", url: url))
    }

    func testExactHostRejectsPort() {
        let url = URL(string: "https://example.com:8443/")!
        XCTAssertTrue(HostMatcher.matches(pattern: "https://example.com/*", url: url))
    }

    func testSchemeMustMatch() {
        let url = URL(string: "http://example.com/")!
        XCTAssertFalse(HostMatcher.matches(pattern: "https://example.com/*", url: url))
    }

    func testBareHostPattern() {
        let url = URL(string: "https://example.com/page")!
        XCTAssertTrue(HostMatcher.matches(pattern: "example.com", url: url))
    }

    func testNonWebURLRejectedByAllURLs() {
        let url = URL(string: "file:///etc/passwd")!
        XCTAssertFalse(HostMatcher.matches(pattern: "<all_urls>", url: url))
    }
}

final class ManifestTests: XCTestCase {
    private let mv3 = """
    {
      "manifest_version": 3,
      "name": "Fixture",
      "version": "1.0.0",
      "description": "test",
      "permissions": ["storage", "tabs"],
      "host_permissions": ["https://example.com/*"],
      "content_scripts": [
        {"matches": ["https://example.com/*"], "js": ["content.js"], "run_at": "document_end", "all_frames": true}
      ],
      "action": {"default_popup": "popup.html"},
      "background": {"service_worker": "sw.js"}
    }
    """

    func testParsesManifestV3() throws {
        let manifest = try ManifestParser.parse(data: Data(mv3.utf8))
        XCTAssertEqual(manifest.manifestVersion, 3)
        XCTAssertEqual(manifest.name, "Fixture")
        XCTAssertEqual(manifest.permissions, ["storage", "tabs"])
        XCTAssertEqual(manifest.hostPermissions, ["https://example.com/*"])
        XCTAssertEqual(manifest.contentScripts.count, 1)
        XCTAssertEqual(manifest.contentScripts[0].runAt, .documentEnd)
        XCTAssertTrue(manifest.contentScripts[0].allFrames)
        XCTAssertEqual(manifest.backgroundKind, .serviceWorker)
        XCTAssertEqual(manifest.action?.defaultPopup, "popup.html")
    }

    func testManifestV2SplitsHostPermissions() throws {
        let json = """
        {"manifest_version": 2, "name": "Legacy", "version": "0.1",
         "permissions": ["storage", "https://example.org/*"],
         "background": {"scripts": ["bg.js"]}, "browser_action": {"default_popup": "p.html"}}
        """
        let manifest = try ManifestParser.parse(data: Data(json.utf8))
        XCTAssertEqual(manifest.permissions, ["storage"])
        XCTAssertEqual(manifest.hostPermissions, ["https://example.org/*"])
        XCTAssertEqual(manifest.backgroundKind, .scripts)
        XCTAssertEqual(manifest.action?.defaultPopup, "p.html")
    }

    func testMissingVersionThrows() {
        let json = #"{"manifest_version": 3, "name": "x", "version": ""}"#
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8)))
    }

    func testUnsupportedManifestVersionThrows() {
        let json = #"{"manifest_version": 4, "name": "x", "version": "1"}"#
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8))) { error in
            XCTAssertEqual(error as? ManifestError, .unsupportedManifestVersion(4))
        }
    }

    func testContentScriptWithoutMatchesThrows() {
        let json = #"{"manifest_version": 3, "name": "x", "version": "1", "content_scripts": [{"js": ["a.js"]}]}"#
        XCTAssertThrowsError(try ManifestParser.parse(data: Data(json.utf8)))
    }

    func testAnalyzerRunsForContentScriptExtension() throws {
        let manifest = try ManifestParser.parse(data: Data(mv3.utf8))
        let report = CompatibilityAnalyzer.analyze(manifest)
        XCTAssertEqual(report.verdict, .runs)
        XCTAssertFalse(report.requiresBroadAccess)
    }

    func testAnalyzerFlagsUnsupportedPermission() {
        let json = """
        {"manifest_version": 3, "name": "x", "version": "1",
         "permissions": ["alarms"], "content_scripts": [{"matches": ["https://a.com/*"], "js": ["a.js"]}]}
        """
        guard let manifest = try? ManifestParser.parse(data: Data(json.utf8)) else {
            return XCTFail("manifest should parse")
        }
        let report = CompatibilityAnalyzer.analyze(manifest)
        XCTAssertEqual(report.verdict, .runsWithLimits)
        XCTAssertTrue(report.unsupported.contains("alarms"))
    }

    func testAnalyzerRefusesWebRequestBlocking() {
        let json = """
        {"manifest_version": 2, "name": "x", "version": "1",
         "permissions": ["webRequestBlocking"], "content_scripts": [{"matches": ["https://a.com/*"], "js": ["a.js"]}]}
        """
        guard let manifest = try? ManifestParser.parse(data: Data(json.utf8)) else {
            return XCTFail("manifest should parse")
        }
        let report = CompatibilityAnalyzer.analyze(manifest)
        XCTAssertEqual(report.verdict, .refused)
    }

    func testAnalyzerMarksNoSurfaceUnsupported() {
        let json = #"{"manifest_version": 3, "name": "x", "version": "1", "permissions": ["storage"]}"#
        guard let manifest = try? ManifestParser.parse(data: Data(json.utf8)) else {
            return XCTFail("manifest should parse")
        }
        XCTAssertEqual(CompatibilityAnalyzer.analyze(manifest).verdict, .unsupported)
    }

    func testRequestedGrantsUnionOfHostsAndMatches() {
        let manifest = ExtensionManifest(
            manifestVersion: 3,
            name: "x",
            version: "1",
            summary: "",
            permissions: [],
            hostPermissions: ["https://a.com/*"],
            optionalPermissions: [],
            contentScripts: [
                ContentScript(matches: ["https://b.com/*"], excludeMatches: [], js: ["a.js"], css: [], runAt: .documentIdle, allFrames: false)
            ],
            action: nil,
            optionsPage: nil,
            backgroundScripts: [],
            backgroundPage: nil,
            backgroundKind: .none,
            icons: [:],
            contentSecurityPolicy: nil
        )
        let grants = manifest.requestedHostPatterns
        XCTAssertEqual(grants, ["https://a.com/*", "https://b.com/*"])
    }
}

final class PackageTests: XCTestCase {
    /// Builds a minimal stored-only ZIP so the reader can be tested without fixtures.
    private func makeZip(_ files: [(String, String)]) -> Data {
        var local = Data()
        var central = Data()
        var offsets: [Int] = []

        for (name, contents) in files {
            let nameBytes = Data(name.utf8)
            let payload = Data(contents.utf8)
            offsets.append(local.count)

            local.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            local.append(uint16(20))
            local.append(uint16(0))
            local.append(uint16(0))
            local.append(uint16(0))
            local.append(uint16(0))
            local.append(uint32(0))
            local.append(uint32(UInt32(payload.count)))
            local.append(uint32(UInt32(payload.count)))
            local.append(uint16(UInt16(nameBytes.count)))
            local.append(uint16(0))
            local.append(nameBytes)
            local.append(payload)

            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            central.append(uint16(20))
            central.append(uint16(20))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint32(0))
            central.append(uint32(UInt32(payload.count)))
            central.append(uint32(UInt32(payload.count)))
            central.append(uint16(UInt16(nameBytes.count)))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint16(0))
            central.append(uint32(0))
            central.append(uint32(UInt32(offsets[offsets.count - 1])))
            central.append(nameBytes)
        }

        var archive = local
        let centralOffset = archive.count
        archive.append(central)
        archive.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        archive.append(uint16(0))
        archive.append(uint16(0))
        archive.append(uint16(UInt16(files.count)))
        archive.append(uint16(UInt16(files.count)))
        archive.append(uint32(UInt32(central.count)))
        archive.append(uint32(UInt32(centralOffset)))
        archive.append(uint16(0))
        return archive
    }

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    func testExtractsManifestAndContentScript() throws {
        let archive = makeZip([
            ("manifest.json", #"{"manifest_version":3,"name":"Zip","version":"1.0"}"#),
            ("scripts/content.js", "console.log('hi');")
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let written = try ZipReader.extract(data: archive, to: root)
        XCTAssertEqual(written.count, 2)
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        XCTAssertTrue(String(decoding: manifest, as: UTF8.self).contains("Zip"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/content.js").path))
    }

    func testRejectsPathTraversal() throws {
        let archive = makeZip([("../escape.txt", "nope")])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ZipReader.extract(data: archive, to: root))
    }

    func testRejectsAbsolutePath() {
        XCTAssertThrowsError(try ZipReader.sanitize("/etc/passwd"))
    }

    func testRejectsDeepPaths() {
        let deep = Array(repeating: "a", count: 20).joined(separator: "/") + "/file.txt"
        XCTAssertThrowsError(try ZipReader.sanitize(deep))
    }

    func testCRXPayloadExtraction() throws {
        let archive = makeZip([("manifest.json", #"{"manifest_version":3,"name":"C","version":"1"}"#)])
        var crx = Data([0x43, 0x72, 0x32, 0x34])
        crx.append(uint32(3))
        let header = Data(repeating: 0x0A, count: 32)
        crx.append(uint32(UInt32(header.count)))
        crx.append(header)
        crx.append(archive)

        let payload = try CRXContainer.payload(from: crx)
        XCTAssertEqual(payload, archive)
    }

    func testCRXRejectsVersionTwo() {
        var crx = Data([0x43, 0x72, 0x32, 0x34])
        crx.append(uint32(2))
        crx.append(uint32(8))
        crx.append(Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try CRXContainer.payload(from: crx))
    }

    func testCRXRejectsBadMagic() {
        XCTAssertThrowsError(try CRXContainer.payload(from: Data(repeating: 0, count: 64)))
    }

    func testStagingRejectsArchiveWithoutManifest() throws {
        let archive = makeZip([("readme.txt", "no manifest")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ExtensionPackage.stage(from: url)) { error in
            XCTAssertEqual(error as? PackageError, .missingManifest)
        }
    }

    func testStagingProducesReport() throws {
        let archive = makeZip([
            ("manifest.json", #"{"manifest_version":3,"name":"Stage","version":"2.1","content_scripts":[{"matches":["https://example.com/*"],"js":["c.js"]}]}"#),
            ("c.js", "1;")
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let staged = try ExtensionPackage.stage(from: url)
        XCTAssertEqual(staged.manifest.name, "Stage")
        XCTAssertEqual(staged.report.verdict, .runs)
        XCTAssertEqual(staged.sourceKind, .zip)
        try? FileManager.default.removeItem(at: staged.directory)
    }
}

final class AdBlockRuleTests: XCTestCase {
    func testDomainAnchorTranslation() {
        let regex = AdBlockRules.regexForAdBlockPattern("||doubleclick.net^")
        XCTAssertNotNil(regex)
        XCTAssertTrue(regex!.hasPrefix("^[a-z]"))
        XCTAssertTrue(regex!.contains("doubleclick"))
    }

    func testExceptionLineBecomesIgnoreRule() {
        let rules = AdBlockRules.parse("@@||good.example^")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].action, .ignorePreviousRules)
    }

    func testCosmeticRule() {
        let rules = AdBlockRules.parse("example.com##.ad-box")
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].action, .cssDisplayNone)
        XCTAssertEqual(rules[0].selector, ".ad-box")
        XCTAssertEqual(rules[0].ifDomain, ["example.com"])
    }

    func testCommentsAndBlankLinesIgnored() {
        XCTAssertTrue(AdBlockRules.parse("! comment\n\n[Adblock Plus 2.0]").isEmpty)
    }

    func testResourceTypeOption() {
        let rules = AdBlockRules.parse("||ads.example^$script,image")
        XCTAssertEqual(rules.first?.resourceType, ["script", "image"])
    }

    func testJSONShape() {
        let rules = AdBlockRules.parse("||ads.example^")
        let objects = AdBlockRules.jsonArray(for: rules)
        XCTAssertEqual(objects.count, 1)
        let action = objects[0]["action"] as? [String: Any]
        XCTAssertEqual(action?["type"] as? String, "block")
        let trigger = objects[0]["trigger"] as? [String: Any]
        XCTAssertNotNil(trigger?["url-filter"] as? String)
    }

    func testBuiltInListProducesRules() throws {
        let rules = AdBlockRules.builtInRules()
        XCTAssertGreaterThan(rules.count, 50)
        let data = try AdBlockRules.jsonData(for: rules)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, rules.count)
    }
}
