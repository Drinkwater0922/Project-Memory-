import Foundation

public enum ActivityDenyList {
    public static let defaultBundleIDs: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess"
    ]

    public static func isDenied(bundleID: String, extraDenied: Set<String> = []) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return defaultBundleIDs.contains(bundleID) || extraDenied.contains(bundleID)
    }
}
