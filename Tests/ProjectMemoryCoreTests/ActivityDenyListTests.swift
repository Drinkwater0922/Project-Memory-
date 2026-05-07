import XCTest
@testable import ProjectMemoryCore

final class ActivityDenyListTests: XCTestCase {
    func testIsDeniedMatchesDefaultBundleIDs() {
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "com.1password.1password"))
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "com.bitwarden.desktop"))
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "org.keepassxc.keepassxc"))
        XCTAssertTrue(ActivityDenyList.isDenied(bundleID: "com.apple.keychainaccess"))
    }

    func testIsDeniedMatchesExtraDenied() {
        XCTAssertTrue(
            ActivityDenyList.isDenied(
                bundleID: "com.example.private",
                extraDenied: ["com.example.private"]
            )
        )
    }

    func testIsDeniedFalseForUnknownAndEmptyExtra() {
        XCTAssertFalse(ActivityDenyList.isDenied(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(
            ActivityDenyList.isDenied(
                bundleID: "com.tinyspeck.slackmacgap",
                extraDenied: []
            )
        )
    }

    func testIsDeniedTrueWhenBothDefaultAndExtra() {
        XCTAssertTrue(
            ActivityDenyList.isDenied(
                bundleID: "com.1password.1password",
                extraDenied: ["com.1password.1password"]
            )
        )
    }

    func testDefaultBundleIDsContainsExpectedHighConfidenceSet() {
        let expected: Set<String> = [
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword4",
            "com.1password.1password",
            "com.bitwarden.desktop",
            "org.keepassxc.keepassxc",
            "com.apple.keychainaccess"
        ]
        XCTAssertEqual(ActivityDenyList.defaultBundleIDs, expected)
    }

    func testIsDeniedDoesNotMatchEmptyBundleIDStringEvenWithEmptyExtra() {
        XCTAssertFalse(ActivityDenyList.isDenied(bundleID: ""))
    }
}
