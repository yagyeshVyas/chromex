import Foundation

/// Minimal Chrome-style `_locales` resolution for `chrome.i18n.getMessage`.
///
/// Supported: `message`, named `placeholders`, positional `$1`-style substitution,
/// and `$$` for a literal dollar sign. Unsupported: plural forms and nested
/// messages, neither of which appear in ordinary extensions.
struct ExtensionLocalization: Sendable {
    struct Message: Sendable {
        var text: String
        /// Placeholder name (lowercased, without `$`) to its `content` value.
        var placeholders: [String: String]
    }

    var locale: String
    var messages: [String: Message]

    /// Loads `_locales/<default_locale>/messages.json`. Falls back to the first
    /// locale folder when the declared one is missing.
    static func load(directory: URL, defaultLocale: String?) -> ExtensionLocalization? {
        let localesRoot = directory.appendingPathComponent("_locales", isDirectory: true)
        let manager = FileManager.default
        guard let locales = try? manager.contentsOfDirectory(
            at: localesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }

        let folders = locales.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard !folders.isEmpty else { return nil }

        let chosen: URL
        if let defaultLocale,
           let match = folders.first(where: { $0.lastPathComponent.caseInsensitiveCompare(defaultLocale) == .orderedSame }) {
            chosen = match
        } else {
            chosen = folders.sorted { $0.lastPathComponent < $1.lastPathComponent }[0]
        }

        let file = chosen.appendingPathComponent("messages.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var parsed: [String: Message] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any], let text = entry["message"] as? String else { continue }
            var placeholders: [String: String] = [:]
            if let raw = entry["placeholders"] as? [String: Any] {
                for (name, placeholder) in raw {
                    if let dict = placeholder as? [String: Any], let content = dict["content"] as? String {
                        placeholders[name.lowercased()] = content
                    }
                }
            }
            parsed[key.lowercased()] = Message(text: text, placeholders: placeholders)
        }

        guard !parsed.isEmpty else { return nil }
        return ExtensionLocalization(locale: chosen.lastPathComponent, messages: parsed)
    }

    func message(for key: String, substitutions: [String]) -> String? {
        guard let message = messages[key.lowercased()] else { return nil }
        var result = ""

        // Resolve $name$ placeholders to their content, substituting "$1" with
        // the first argument, and keep unknown placeholders verbatim.
        var index = message.text.startIndex
        while index < message.text.endIndex {
            let character = message.text[index]
            if character == "$" {
                let next = message.text.index(after: index)
                if next < message.text.endIndex, message.text[next] == "$" {
                    result.append("$")
                    index = message.text.index(after: next)
                    continue
                }
                if let closing = message.text[next...].firstIndex(of: "$") {
                    let name = String(message.text[next..<closing]).lowercased()
                    if let content = message.placeholders[name] {
                        result += resolve(content, substitutions: substitutions)
                    } else if let number = Int(name), number >= 1, number <= substitutions.count {
                        result += substitutions[number - 1]
                    } else {
                        result += "$" + name + "$"
                    }
                    index = message.text.index(after: closing)
                    continue
                }
            }
            result.append(character)
            index = message.text.index(after: index)
        }

        return result
    }

    private func resolve(_ content: String, substitutions: [String]) -> String {
        if content.hasPrefix("$"), content.hasSuffix("$"), content.count > 2 {
            let name = String(content.dropFirst().dropLast()).lowercased()
            if let number = Int(name), number >= 1, number <= substitutions.count {
                return substitutions[number - 1]
            }
            if let nested = messages[name] {
                return nested.text
            }
        }
        if let number = Int(content), number >= 1, number <= substitutions.count {
            return substitutions[number - 1]
        }
        return content
    }
}
