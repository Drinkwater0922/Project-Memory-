import Foundation

public enum SupportedBrowsers {
    public enum Dialect: Equatable {
        case safari
        case chromium
    }

    public static let safariBundleID = "com.apple.Safari"

    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser"
    ]

    public static let bundleIDs: Set<String> = chromiumBundleIDs.union([safariBundleID])

    public static func dialect(for bundleID: String) -> Dialect? {
        if bundleID == safariBundleID { return .safari }
        if chromiumBundleIDs.contains(bundleID) { return .chromium }
        return nil
    }
}
