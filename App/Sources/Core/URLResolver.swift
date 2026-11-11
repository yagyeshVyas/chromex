import Foundation

/// Turns whatever a user typed into either a URL or a search.
///
/// The rules are deliberately boring and testable: an explicit scheme wins, a
/// bare host that looks like a host is upgraded to HTTPS, everything else is a
/// search. No network access, no heuristics that need the internet.
enum URLResolver {
    /// Hosts that are valid without a dot (intranet names, dev servers).
    private static let dotlessHosts: Set<String> = ["localhost"]

    static func destination(for rawInput: String, engine: SearchEngine) -> URL? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = explicitURL(from: input) {
            return url
        }

        if looksLikeHost(input) {
            let scheme = isLocalHost(input) ? "http" : "https"
            if let url = URL(string: "\(scheme)://\(input)"), url.host != nil {
                return url
            }
        }

        return engine.url(for: input)
    }

    /// Returns a URL only when the input carries an explicit, supported scheme.
    static func explicitURL(from input: String) -> URL? {
        guard let colon = input.firstIndex(of: ":") else { return nil }
        let scheme = input[input.startIndex..<colon].lowercased()
        let supported: Set<String> = ["http", "https", "file", "about", "ftp"]
        guard supported.contains(scheme) else { return nil }
        return URL(string: input)
    }

    /// A host is accepted when it has no spaces, a valid character set, and
    /// either a dot, a port, an IPv4 shape, or is a known dotless host.
    static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        let head = String(input.prefix { $0 != "/" && $0 != ":" && $0 != "?" && $0 != "#" })
        guard !head.isEmpty, isValidHostComponent(head) else { return false }
        if dotlessHosts.contains(head.lowercased()) { return true }
        if isIPv4Address(head) { return true }
        guard let dot = head.lastIndex(of: ".") else { return false }
        let tld = head[head.index(after: dot)...]
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    static func isIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return value >= 0 && value <= 255
        }
    }

    private static func isValidHostComponent(_ host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_:[]")
        guard host.lowercased().unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    private static func isLocalHost(_ input: String) -> Bool {
        let head = String(input.prefix { $0 != ":" && $0 != "/" }).lowercased()
        return dotlessHosts.contains(head) || head.hasPrefix("127.0.0.1")
    }

    /// Compact form for the omnibox: no scheme, no trailing slash, no `www.`.
    static func displayString(for url: URL?) -> String {
        guard let url, let host = url.host else { return url?.absoluteString ?? "" }
        var display = host
        if display.hasPrefix("www.") { display.removeFirst(4) }
        let path = url.path
        if !path.isEmpty && path != "/" { display += path }
        if let query = url.query, !query.isEmpty { display += "?" + query }
        return display
    }

    /// Used to decide whether history should record a visit.
    static func isWebURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
