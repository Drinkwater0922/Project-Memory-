import Foundation

public enum URLDenyList {
    public static func isDenied(_ url: String) -> Bool {
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?
            .host?
            .lowercased(),
            !host.isEmpty
        else {
            return true
        }

        if host == "localhost" || host == "127.0.0.1" {
            return true
        }
        if host.hasSuffix(".lan") || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") {
            return true
        }
        if is172PrivateHost(host) {
            return true
        }

        // Host label exact match — avoids substring false negatives like
        // `myaccount.google.com` not matching keyword `accounts.`
        // (and also tightens against false positives like `bank-statistics.gov`
        // accidentally matching `bank`).
        let labels = host.split(separator: ".").map(String.init)
        return labels.contains { sensitiveHostLabels.contains($0) }
    }

    /// Host labels that, when present anywhere in a URL host, mark the URL as
    /// sensitive and exclude it from activity capture / web capture pipelines.
    /// Match is case-insensitive (host is lowercased before comparison) and
    /// label-exact (e.g. `account` matches `account.microsoft.com` but not
    /// `accounting.example.com`).
    private static let sensitiveHostLabels: Set<String> = [
        "account",
        "accounts",
        "myaccount",
        "login",
        "signin",
        "auth",
        "oauth",
        "mail",
        "password",
        "bank"
    ]

    public static func normalizeForDedup(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.host != nil
        else {
            return trimmed
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil

        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        if let queryItems = components.queryItems {
            let filtered = queryItems
                .filter { item in
                    let name = item.name.lowercased()
                    return !name.hasPrefix("utm_")
                        && name != "fbclid"
                        && name != "gclid"
                }
                .sorted { lhs, rhs in
                    if lhs.name == rhs.name {
                        return (lhs.value ?? "") < (rhs.value ?? "")
                    }
                    return lhs.name < rhs.name
                }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }

        return components.string ?? trimmed
    }

    private static func is172PrivateHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count >= 2,
              parts[0] == "172",
              let second = Int(parts[1])
        else {
            return false
        }
        return (16...31).contains(second)
    }
}
