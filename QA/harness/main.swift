import Foundation

// MARK: - Tiny test harness

var checks: [(name: String, passed: Bool, detail: String)] = []

func expect(_ condition: Bool, _ name: String, _ detail: String = "") {
    checks.append((name, condition, detail))
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ name: String) {
    expect(lhs == rhs, name, "expected \(rhs), got \(lhs)")
}

// MARK: - Paths

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fixtures = root.appendingPathComponent("QA/fixtures")
let reports = root.appendingPathComponent("QA/reports")
try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)

// MARK: - URL resolution

let engine = SearchEngine.builtIns[0]

expectEqual(URLResolver.destination(for: "example.com", engine: engine)?.absoluteString,
            "https://example.com", "bare domain upgrades to https")
expectEqual(URLResolver.destination(for: "http://example.com/a?b=1", engine: engine)?.absoluteString,
            "http://example.com/a?b=1", "explicit scheme preserved")
expectEqual(URLResolver.destination(for: "localhost:3000", engine: engine)?.host,
            "localhost", "localhost host parsed")
expectEqual(URLResolver.destination(for: "localhost:3000", engine: engine)?.scheme,
            "http", "localhost uses http")
expectEqual(URLResolver.destination(for: "best phone 2026", engine: engine)?.host,
            "www.google.com", "free text becomes a search")
expectEqual(URLResolver.destination(for: "javascript:alert(1)", engine: engine)?.host,
            "www.google.com", "javascript scheme is not navigated")
expectEqual(URLResolver.displayString(for: URL(string: "https://www.example.com/path")),
            "example.com/path", "display strips scheme and www")
expect(URLResolver.destination(for: "   ", engine: engine) == nil, "empty input returns nil")
expect(URLResolver.destination(for: "192.168.1.1", engine: engine)?.host == "192.168.1.1",
       "IPv4 address treated as host")

// MARK: - Host matching

expect(HostMatcher.matches(pattern: "<all_urls>", url: URL(string: "https://a.example")!),
       "<all_urls> matches https")
expect(!HostMatcher.matches(pattern: "<all_urls>", url: URL(string: "file:///etc/passwd")!),
       "<all_urls> rejects file scheme")
expect(HostMatcher.matches(pattern: "*://*.example.com/*", url: URL(string: "https://api.example.com/x")!),
       "wildcard subdomain matches")
expect(!HostMatcher.matches(pattern: "https://example.com/*", url: URL(string: "http://example.com/")!),
       "scheme mismatch rejected")
expect(HostMatcher.matches(pattern: "example.com", url: URL(string: "https://example.com/p")!),
       "bare host pattern matches")

// MARK: - Ad-block rules

let builtIn = AdBlockRules.builtInRules()
expect(builtIn.count > 50, "built-in list yields rules", "count=\(builtIn.count)")
if let regex = AdBlockRules.regexForAdBlockPattern("||doubleclick.net^") {
    expect(regex.hasPrefix("^[a-z]"), "domain anchor compiles to scheme-anchored regex")
} else {
    expect(false, "domain anchor compiles to regex")
}
expect(AdBlockRules.parse("example.com##.ad").first?.action == .cssDisplayNone,
       "cosmetic rule parsed")
expect(AdBlockRules.parse("@@||good.example^").first?.action == .ignorePreviousRules,
       "exception rule parsed")

// MARK: - Fixture expectations

struct FixtureExpectation {
    let name: String
    let verdict: CompatibilityVerdict?
    let mustThrow: Bool
    let missingManifest: Bool
}

let expectations: [FixtureExpectation] = [
    .init(name: "basic-content", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "dark-mode", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "ad-blocker", verdict: .runsWithLimits, mustThrow: false, missingManifest: false),
    .init(name: "popup", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "storage", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "messaging", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "background-mv2", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "permission-restricted", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "unsupported-api", verdict: .runsWithLimits, mustThrow: false, missingManifest: false),
    .init(name: "broad-access", verdict: .runs, mustThrow: false, missingManifest: false),
    .init(name: "malformed", verdict: nil, mustThrow: true, missingManifest: false),
    .init(name: "missing-manifest", verdict: nil, mustThrow: true, missingManifest: true),
]

var analyses: [(name: String, manifest: ExtensionManifest?, report: CompatibilityReport?, error: String?)] = []

for expectation in expectations {
    let directory = fixtures.appendingPathComponent(expectation.name)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let exists = FileManager.default.fileExists(atPath: manifestURL.path)

    if expectation.missingManifest {
        expect(!exists, "\(expectation.name): manifest absent as designed")
        analyses.append((expectation.name, nil, nil, "manifest.json missing"))
        continue
    }

    guard exists, let data = try? Data(contentsOf: manifestURL) else {
        expect(false, "\(expectation.name): manifest readable")
        analyses.append((expectation.name, nil, nil, "unreadable"))
        continue
    }

    do {
        let manifest = try ManifestParser.parse(data: data)
        if expectation.mustThrow {
            expect(false, "\(expectation.name): expected parse failure")
            analyses.append((expectation.name, nil, nil, "unexpectedly parsed"))
            continue
        }
        let report = CompatibilityAnalyzer.analyze(manifest)
        expectEqual(report.verdict, expectation.verdict ?? report.verdict,
                    "\(expectation.name): verdict \(report.verdict.rawValue)")
        analyses.append((expectation.name, manifest, report, nil))
    } catch {
        if expectation.mustThrow {
            expect(true, "\(expectation.name): rejected with \(error.localizedDescription)")
            analyses.append((expectation.name, nil, nil, error.localizedDescription))
        } else {
            expect(false, "\(expectation.name): unexpected parse failure \(error)")
            analyses.append((expectation.name, nil, nil, "\(error)"))
        }
    }
}

// Permission-gating invariants
if let snapshot = analyses.first(where: { $0.name == "permission-restricted" }),
   let manifest = snapshot.manifest {
    expectEqual(manifest.requestedHostPatterns, ["https://allowed.example.com/*"],
                "permission-restricted: exactly one consent pattern")
}
if let snapshot = analyses.first(where: { $0.name == "broad-access" }),
   let report = snapshot.report {
    expect(report.requiresBroadAccess, "broad-access: flagged as broad access")
}
if let snapshot = analyses.first(where: { $0.name == "unsupported-api" }),
   let report = snapshot.report {
    expect(report.unsupported.count >= 2, "unsupported-api: at least two unsupported APIs",
           "unsupported=\(report.unsupported)")
    expect(report.findings.allSatisfy { $0.status != .supported },
           "unsupported-api: findings carry status")
}
if let snapshot = analyses.first(where: { $0.name == "ad-blocker" }),
   let report = snapshot.report {
    expect(report.unsupported.contains("declarativeNetRequest"),
           "ad-blocker: DNR reported unsupported")
}

// MARK: - Benchmarks (real numbers, this host)

func measure(_ label: String, iterations: Int, _ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    let end = DispatchTime.now().uptimeNanoseconds
    let ms = Double(end - start) / 1_000_000
    print(String(format: "  %-34s %8.2f ms total, %8.4f ms/op",
                 (label as NSString).utf8String!, ms, ms / Double(iterations)))
    return ms
}

print("\n== benchmarks ==")
let urlTotal = measure("URLResolver.destination", iterations: 20_000) {
    _ = URLResolver.destination(for: "example.com/path?q=1", engine: engine)
}
let manifestTotal = measure("ManifestParser.parse", iterations: 2_000) {
    _ = try? ManifestParser.parse(data: Data(#"{"manifest_version":3,"name":"Bench","version":"1"}"#.utf8))
}
let analyzeTotal = measure("CompatibilityAnalyzer.analyze", iterations: 2_000) {
    if let m = try? ManifestParser.parse(data: Data(#"{"manifest_version":3,"name":"Bench","version":"1","content_scripts":[{"matches":["https://a.com/*"],"js":["a.js"]}]}"#.utf8)) {
        _ = CompatibilityAnalyzer.analyze(m)
    }
}
let rulesTotal = measure("AdBlockRules.parse (built-in list)", iterations: 200) {
    _ = AdBlockRules.parse(AdBlockRules.builtInList)
}

// MARK: - Compatibility reports

func classify(_ report: CompatibilityReport?) -> String {
    guard let report else { return "Incompatible" }
    switch report.verdict {
    case .refused, .unsupported:
        return "Incompatible"
    case .runs, .runsWithLimits:
        return "Partially compatible — analysis only, runtime untested"
    }
}

for analysis in analyses {
    let directory = reports
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var lines: [String] = []
    lines.append("# \(analysis.name) — compatibility report")
    lines.append("")
    lines.append("**Classification:** \(classify(analysis.report))")
    lines.append("")
    if let manifest = analysis.manifest {
        lines.append("| Field | Value |")
        lines.append("|---|---|")
        lines.append("| Manifest version | \(manifest.manifestVersion) |")
        lines.append("| Name | \(manifest.name) |")
        lines.append("| Version | \(manifest.version) |")
        lines.append("| Declared permissions | \(manifest.permissions.isEmpty ? "none" : manifest.permissions.joined(separator: ", ")) |")
        lines.append("| Host patterns | \(manifest.requestedHostPatterns.isEmpty ? "none" : manifest.requestedHostPatterns.joined(separator: ", ")) |")
        lines.append("| Content scripts | \(manifest.contentScripts.count) |")
        lines.append("| Background | \(manifest.backgroundKind.rawValue) |")
        lines.append("| Popup | \(manifest.action?.defaultPopup ?? "none") |")
        lines.append("")
    }
    if let report = analysis.report {
        lines.append("## Analysis result")
        lines.append("")
        lines.append("- Verdict: `\(report.verdict.rawValue)` — \(report.verdict.explanation)")
        lines.append("- Score: \(report.score)/100")
        lines.append("- Broad host access: \(report.requiresBroadAccess ? "yes" : "no")")
        lines.append("- Supported APIs: \(report.supported.isEmpty ? "none" : report.supported.joined(separator: ", "))")
        lines.append("- Unsupported APIs: \(report.unsupported.isEmpty ? "none" : report.unsupported.joined(separator: ", "))")
        lines.append("")
        if !report.findings.isEmpty {
            lines.append("| API | Status | Note |")
            lines.append("|---|---|---|")
            for finding in report.findings {
                lines.append("| \(finding.api) | \(finding.status.rawValue) | \(finding.message) |")
            }
            lines.append("")
        }
    } else {
        lines.append("## Analysis result")
        lines.append("")
        lines.append("Rejected before analysis: \(analysis.error ?? "unknown error")")
        lines.append("")
    }

    lines.append("## Execution results (device required)")
    lines.append("")
    lines.append("| Check | Result |")
    lines.append("|---|---|")
    lines.append("| Installation | Not run on device — validated at analysis level only |")
    lines.append("| Content-script injection | Not run on device |")
    lines.append("| Background execution | Not run on device |")
    lines.append("| Popup rendering | Not run on device |")
    lines.append("| Storage round-trip | Not run on device |")
    lines.append("| Runtime errors | Not collected |")
    lines.append("")
    lines.append("> Classification stays at *partially compatible* until these are executed on a signed build.")
    lines.append("")

    let target = reports.appendingPathComponent("\(analysis.name).md")
    try? lines.joined(separator: "\n").write(to: target, atomically: true, encoding: .utf8)
}

// MARK: - Summary

let failures = checks.filter { !$0.passed }
print("\n== summary ==")
print("checks: \(checks.count), failures: \(failures.count)")
for failure in failures {
    print("FAIL: \(failure.name) \(failure.detail)")
}
print(String(format: "benchmarks: url=%.1fms manifest=%.1fms analyze=%.1fms rules=%.1fms",
             urlTotal, manifestTotal, analyzeTotal, rulesTotal))
print("reports: \(analyses.count) written to QA/reports")

exit(failures.isEmpty ? 0 : 1)
