import Foundation

/// A content-blocking rule expressed in WebKit's vocabulary.
///
/// This is the pure half of the blocker: text in, rule objects out. It is
/// deliberately a subset of EasyList and says so — see
/// `EXTENSION-COMPATIBILITY.md` for exactly what is and is not understood.
enum RuleActionKind: String, Sendable, Hashable {
    case block
    case cssDisplayNone = "css-display-none"
    case ignorePreviousRules = "ignore-previous-rules"
}

struct FilterRule: Sendable, Hashable {
    var action: RuleActionKind
    var selector: String?
    var urlFilter: String?
    var ifDomain: [String]?
    var resourceType: [String]?
}

enum AdBlockRules {
    /// Domains blocked out of the box. Small, curated, and safe to ship offline.
    static let builtInList: String = """
    ! CHROMEX built-in filter list
    ||doubleclick.net^
    ||googlesyndication.com^
    ||googleadservices.com^
    ||google-analytics.com^
    ||googletagmanager.com^
    ||googletagservices.com^
    ||adservice.google.com^
    ||amazon-adsystem.com^
    ||facebook.net^$script
    ||connect.facebook.net^
    ||scorecardresearch.com^
    ||quantserve.com^
    ||criteo.com^
    ||criteo.net^
    ||taboola.com^
    ||outbrain.com^
    ||adnxs.com^
    ||rubiconproject.com^
    ||pubmatic.com^
    ||openx.net^
    ||casalemedia.com^
    ||smartadserver.com^
    ||sharethrough.com^
    ||teads.tv^
    ||moatads.com^
    ||adcolony.com^
    ||applovin.com^
    ||unityads.unity3d.com^
    ||inmobi.com^
    ||mopub.com^
    ||chartboost.com^
    ||hotjar.com^
    ||fullstory.com^
    ||mouseflow.com^
    ||luckyorange.com^
    ||segment.io^
    ||segment.com^
    ||mixpanel.com^
    ||amplitude.com^
    ||heap.io^
    ||kissmetrics.com^
    ||newrelic.com$script
    ||bugsnag.com$script
    ||sentry-cdn.com$script
    ||branch.io^
    ||adjust.com^
    ||appsflyer.com^
    ||kochava.com^
    ||singular.net^
    ||onesignal.com^$script
    ||pushengage.com^
    ||cleverpush.com^
    ||pushwoosh.com^
    ##.ad-banner
    ##.ad-container
    ##.ad-slot
    ##.ad-wrapper
    ##.adsbygoogle
    ##.advertisement
    ##[id^="google_ads"]
    ##[id^="div-gpt-ad"]
    ##[class^="ad-slot-"]
    ##[data-ad-slot]
    ##.sponsored-content
    ##.taboola-container
    ##.outbrain-widget
    """

    /// Parses the supported subset of EasyList syntax.
    static func parse(_ text: String) -> [FilterRule] {
        var rules: [FilterRule] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.hasPrefix("# ") else {
                continue
            }
            if let cosmetic = parseCosmetic(line) {
                rules.append(cosmetic)
                continue
            }
            if let network = parseNetwork(line) {
                rules.append(network)
            }
        }
        return rules
    }

    private static func parseCosmetic(_ line: String) -> FilterRule? {
        guard let separator = line.range(of: "##") else { return nil }
        let domainPart = String(line[line.startIndex..<separator.lowerBound])
        let selector = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return nil }
        let domains = domainPart
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("~") }
        return FilterRule(
            action: .cssDisplayNone,
            selector: selector,
            urlFilter: ".*",
            ifDomain: domains.isEmpty ? nil : domains,
            resourceType: nil
        )
    }

    private static func parseNetwork(_ line: String) -> FilterRule? {
        var pattern = line
        var isException = false
        if pattern.hasPrefix("@@") {
            isException = true
            pattern.removeFirst(2)
        }

        var resourceTypes: [String] = []
        if let dollar = pattern.lastIndex(of: "$") {
            let options = pattern[pattern.index(after: dollar)...].split(separator: ",").map(String.init)
            pattern = String(pattern[pattern.startIndex..<dollar])
            for option in options {
                switch option {
                case "image": resourceTypes.append("image")
                case "script": resourceTypes.append("script")
                case "stylesheet", "css": resourceTypes.append("style-sheet")
                case "subdocument": resourceTypes.append("child-document")
                case "font": resourceTypes.append("font")
                case "media": resourceTypes.append("media")
                case "xmlhttprequest", "xhr": resourceTypes.append("fetch")
                default: break
                }
            }
        }

        guard !pattern.isEmpty else { return nil }
        guard let regex = regexForAdBlockPattern(pattern) else { return nil }

        if isException {
            return FilterRule(
                action: .ignorePreviousRules,
                selector: nil,
                urlFilter: regex,
                ifDomain: nil,
                resourceType: resourceTypes.isEmpty ? nil : resourceTypes
            )
        }
        return FilterRule(
            action: .block,
            selector: nil,
            urlFilter: regex,
            ifDomain: nil,
            resourceType: resourceTypes.isEmpty ? nil : resourceTypes
        )
    }

    /// Translates a conservative subset of Adblock syntax into a WebKit-compatible
    /// regex. Anything it does not understand is skipped rather than guessed at.
    static func regexForAdBlockPattern(_ pattern: String) -> String? {
        var body = pattern
        var prefix = ""
        var suffix = ""

        if body.hasPrefix("||") {
            body.removeFirst(2)
            prefix = "^[a-z][a-z0-9+.-]*://([^/?#]*\\.)?"
        } else if body.hasPrefix("|") {
            body.removeFirst()
            prefix = "^"
        }

        if body.hasSuffix("|") {
            body.removeLast()
            suffix = "$"
        }

        var regex = ""
        for character in body {
            switch character {
            case "*":
                regex += ".*"
            case "^":
                regex += "(?:[^a-zA-Z0-9_\\-.%]|$)"
            default:
                regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard !regex.isEmpty else { return nil }
        return prefix + regex + suffix
    }

    /// WebKit's JSON shape for one rule.
    static func jsonObject(for rule: FilterRule) -> [String: Any]? {
        guard let urlFilter = rule.urlFilter, !urlFilter.isEmpty else { return nil }
        var trigger: [String: Any] = ["url-filter": urlFilter]
        if let domains = rule.ifDomain, !domains.isEmpty {
            trigger["if-domain"] = domains.map { "*" + $0 }
        }
        if let types = rule.resourceType, !types.isEmpty {
            trigger["resource-type"] = types
        }
        var action: [String: Any] = ["type": rule.action.rawValue]
        if rule.action == .cssDisplayNone {
            action["selector"] = rule.selector ?? ""
        }
        return ["trigger": trigger, "action": action]
    }

    static func jsonArray(for rules: [FilterRule]) -> [[String: Any]] {
        rules.compactMap(jsonObject(for:))
    }

    static func jsonData(for rules: [FilterRule]) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonArray(for: rules), options: [])
    }

    /// Convenience used by the app at launch.
    static func builtInRules() -> [FilterRule] {
        parse(builtInList)
    }
}
