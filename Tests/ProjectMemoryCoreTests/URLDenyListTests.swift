import XCTest
@testable import ProjectMemoryCore

final class URLDenyListTests: XCTestCase {
    func testIsDeniedBlocksSensitiveHosts() {
        XCTAssertTrue(URLDenyList.isDenied("https://bank.example.com/account"))
        XCTAssertTrue(URLDenyList.isDenied("https://accounts.google.com/o/oauth2/v2/auth"))
        XCTAssertTrue(URLDenyList.isDenied("https://login.example.com/sso"))
    }

    func testIsDeniedBlocksPrivateNetworks() {
        XCTAssertTrue(URLDenyList.isDenied("http://192.168.1.10/admin"))
        XCTAssertTrue(URLDenyList.isDenied("http://10.0.0.5/router"))
        XCTAssertTrue(URLDenyList.isDenied("http://172.20.10.5/admin"))
        XCTAssertTrue(URLDenyList.isDenied("http://localhost:3000/debug"))
        XCTAssertTrue(URLDenyList.isDenied("http://router.lan/status"))
    }

    func testIsDeniedReturnsTrueForUnparseableURL() {
        XCTAssertTrue(URLDenyList.isDenied("not a url"))
        XCTAssertTrue(URLDenyList.isDenied(""))
    }

    func testIsDeniedAllowsBenignHosts() {
        XCTAssertFalse(URLDenyList.isDenied("https://example.com/article"))
        XCTAssertFalse(URLDenyList.isDenied("https://swift.org/documentation"))
        XCTAssertFalse(URLDenyList.isDenied("https://github.com/swift"))
        XCTAssertFalse(URLDenyList.isDenied("https://stackoverflow.com/q/123"))
    }

    func testIsDeniedBlocksSubdomainAccountVariants() {
        // Smoke-test regression: substring match missed `myaccount.google.com`
        // because the keyword was `accounts.` (plural + dot). Host-label match
        // handles all the natural variants.
        XCTAssertTrue(URLDenyList.isDenied("https://myaccount.google.com/"))
        XCTAssertTrue(URLDenyList.isDenied("https://account.microsoft.com/profile"))
        XCTAssertTrue(URLDenyList.isDenied("https://accounts.google.com/"))
        XCTAssertTrue(URLDenyList.isDenied("https://signin.aws.amazon.com/"))
        XCTAssertTrue(URLDenyList.isDenied("https://oauth.example.com/token"))
        XCTAssertTrue(URLDenyList.isDenied("https://mail.google.com/"))
    }

    func testIsDeniedDoesNotMatchHyphenatedLabels() {
        // Host labels are matched exactly, so `bank-statistics.gov` is allowed
        // (the label is `bank-statistics`, not `bank`). Same for `mail-list`.
        XCTAssertFalse(URLDenyList.isDenied("https://bank-statistics.gov/report"))
        XCTAssertFalse(URLDenyList.isDenied("https://mail-list.example.com/"))
    }

    func testNormalizeForDedupRemovesTrackingAndFragment() {
        let a = URLDenyList.normalizeForDedup(
            "https://EXAMPLE.com/article/?utm_source=newsletter&fbclid=abc&keep=1#section"
        )
        let b = URLDenyList.normalizeForDedup("https://example.com/article/?keep=1")
        XCTAssertEqual(a, b)
    }

    func testNormalizeForDedupTreatsTrailingSlashAsEquivalent() {
        XCTAssertEqual(
            URLDenyList.normalizeForDedup("https://Example.com/article/"),
            URLDenyList.normalizeForDedup("https://example.com/article")
        )
    }
}
