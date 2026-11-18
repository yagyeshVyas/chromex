import XCTest

final class LocalizationTests: XCTestCase {
    private func makeExtension(messages: [String: Any], locale: String = "en") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromex-l10n-\(UUID().uuidString)", isDirectory: true)
        let messagesDirectory = root
            .appendingPathComponent("_locales", isDirectory: true)
            .appendingPathComponent(locale, isDirectory: true)
        try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: messages)
        try data.write(to: messagesDirectory.appendingPathComponent("messages.json"))
        return root
    }

    func testLoadsAndSubstitutesNamedPlaceholder() throws {
        let root = try makeExtension(messages: [
            "greeting": [
                "message": "Hello $USER$",
                "placeholders": ["user": ["content": "$1"]]
            ]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let localization = ExtensionLocalization.load(directory: root, defaultLocale: "en")
        XCTAssertNotNil(localization)
        XCTAssertEqual(localization?.locale, "en")
        XCTAssertEqual(localization?.message(for: "greeting", substitutions: ["Ada"]), "Hello Ada")
    }

    func testPositionalSubstitution() throws {
        let root = try makeExtension(messages: [
            "open": ["message": "Open $1 in $2"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let localization = ExtensionLocalization.load(directory: root, defaultLocale: "en")
        XCTAssertEqual(localization?.message(for: "open", substitutions: ["tab", "CHROMEX"]), "Open tab in CHROMEX")
    }

    func testMissingKeyReturnsNil() throws {
        let root = try makeExtension(messages: ["known": ["message": "Known"]])
        defer { try? FileManager.default.removeItem(at: root) }

        let localization = ExtensionLocalization.load(directory: root, defaultLocale: "en")
        XCTAssertNil(localization?.message(for: "unknown", substitutions: []))
    }

    func testLiteralDollarAndUnknownPlaceholderSurvive() throws {
        let root = try makeExtension(messages: [
            "price": ["message": "Costs $$5, placeholder $MISSING$ stays"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let localization = ExtensionLocalization.load(directory: root, defaultLocale: "en")
        let value = localization?.message(for: "price", substitutions: [])
        XCTAssertEqual(value, "Costs $5, placeholder $missing$ stays")
    }

    func testUnknownDefaultLocaleFallsBackToAvailableFolder() throws {
        let root = try makeExtension(messages: ["hello": ["message": "Bonjour"]], locale: "fr")
        defer { try? FileManager.default.removeItem(at: root) }

        let localization = ExtensionLocalization.load(directory: root, defaultLocale: "de")
        XCTAssertEqual(localization?.locale, "fr")
        XCTAssertEqual(localization?.message(for: "hello", substitutions: []), "Bonjour")
    }

    func testManifestParsesDefaultLocale() throws {
        let json = #"{"manifest_version":3,"name":"x","version":"1","default_locale":"fr"}"#
        let manifest = try ManifestParser.parse(data: Data(json.utf8))
        XCTAssertEqual(manifest.defaultLocale, "fr")
        XCTAssertFalse(CompatibilityAnalyzer.analyze(manifest).unsupported.contains("i18n"))
    }
}
