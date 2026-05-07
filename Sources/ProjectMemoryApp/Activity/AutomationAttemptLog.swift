import Foundation

internal enum AutomationOutcome: Equatable, Codable {
    case notAttempted
    case success(at: Date)
    case failure(at: Date, reason: String)
}

internal final class AutomationAttemptLog {
    private static let defaultsKey = "ProjectMemory.automationAttemptLog"

    private let defaults: UserDefaults
    private var cache: [String: AutomationOutcome]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: AutomationOutcome].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    func outcome(forBundleID bundleID: String) -> AutomationOutcome {
        cache[bundleID] ?? .notAttempted
    }

    func recordSuccess(bundleID: String, at: Date = Date()) {
        cache[bundleID] = .success(at: at)
        persist()
    }

    func recordFailure(bundleID: String, at: Date = Date(), reason: String) {
        cache[bundleID] = .failure(at: at, reason: reason)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
