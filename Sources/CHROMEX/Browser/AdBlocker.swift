import Foundation
import WebKit

/// WebKit hands rule lists back from asynchronous callbacks; they are immutable
/// once compiled, so passing the reference across an actor hop is safe.
extension WKContentRuleList: @retroactive @unchecked Sendable {}

/// Compiles the built-in filter list into a `WKContentRuleList` and attaches it
/// to tab configurations.
///
/// WebKit exposes no per-request interception hook, so this is the only honest
/// form of blocking available to an iOS browser. The privacy dashboard reports
/// rules compiled and protection state — never a fabricated "trackers blocked"
/// number.
@MainActor
final class AdBlocker: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var ruleCount = 0
    @Published private(set) var lastError: String?

    private var compiledList: WKContentRuleList?
    private let store: WKContentRuleListStore?
    private static let identifier = "CHROMEX-BuiltIn-v1"

    init() {
        store = WKContentRuleListStore.default()
    }

    func prepare() {
        guard !isReady, compiledList == nil else { return }
        guard let store else {
            lastError = "The content-blocking store is unavailable on this device."
            return
        }
        store.lookUpContentRuleList(forIdentifier: Self.identifier) { [weak self] list, _ in
            Task { @MainActor in
                if let list {
                    self?.finish(list)
                } else {
                    self?.compile()
                }
            }
        }
    }

    func attach(to configuration: WKWebViewConfiguration) {
        guard isReady, let compiledList else { return }
        configuration.userContentController.add(compiledList)
    }

    private func compile() {
        let rules = AdBlockRules.builtInRules()
        ruleCount = rules.count
        guard !rules.isEmpty else {
            lastError = "The built-in filter list produced no rules."
            return
        }
        guard
            let store,
            let data = try? AdBlockRules.jsonData(for: rules),
            let encoded = String(data: data, encoding: .utf8)
        else {
            lastError = "Could not encode the filter list."
            return
        }

        store.compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: encoded) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                if let list {
                    self.finish(list)
                } else {
                    self.lastError = error?.localizedDescription ?? "WebKit rejected the filter list."
                }
            }
        }
    }

    private func finish(_ list: WKContentRuleList) {
        compiledList = list
        isReady = true
        lastError = nil
        if ruleCount == 0 {
            ruleCount = AdBlockRules.builtInRules().count
        }
    }
}
