import Foundation

public enum ActivityGate {
    public enum Decision: Equatable {
        case capture
        case skip(reason: String)
    }

    public static let rateLimitInterval: TimeInterval = 5

    public static func decide(
        candidate: ActivityCandidate,
        now: Date,
        lastCaptureAt: Date?,
        extraDenied: Set<String>
    ) -> Decision {
        if ActivityDenyList.isDenied(bundleID: candidate.bundleID, extraDenied: extraDenied) {
            return .skip(reason: "app_denied")
        }
        if let url = candidate.browserURL, URLDenyList.isDenied(url) {
            return .skip(reason: "url_denied")
        }
        if let last = lastCaptureAt, now.timeIntervalSince(last) < rateLimitInterval {
            return .skip(reason: "rate_limited")
        }
        return .capture
    }
}
