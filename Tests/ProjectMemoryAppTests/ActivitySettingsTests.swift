import XCTest
@testable import ProjectMemoryApp
@testable import ProjectMemoryCore

@MainActor
final class ActivitySettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ActivitySettingsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAddRejectsEmptyAfterTrim() {
        var list: [String] = []
        let result = ActivitySettings.tryAddExtraDeniedBundleID("   \n", current: list)
        if case .rejectedEmpty = result {} else { XCTFail("\(result)") }
        if case .added(_, let next) = result { list = next }
        XCTAssertEqual(list, [])
    }

    func testAddRejectsAlreadyInDefaults() {
        let result = ActivitySettings.tryAddExtraDeniedBundleID("com.1password.1password", current: [])
        if case .rejectedAlreadyInDefaults = result {} else { XCTFail("\(result)") }
    }

    func testAddRejectsDuplicate() {
        let result = ActivitySettings.tryAddExtraDeniedBundleID("com.example.private",
                                                                current: ["com.example.private"])
        if case .rejectedDuplicate = result {} else { XCTFail("\(result)") }
    }

    func testAddSuccessTrimsAndSanitizes() {
        let result = ActivitySettings.tryAddExtraDeniedBundleID("  com.example.x\u{200B}\n", current: [])
        if case .added(let cleaned, let next) = result {
            XCTAssertEqual(cleaned, "com.example.x")
            XCTAssertEqual(next, ["com.example.x"])
        } else { XCTFail("\(result)") }
    }
}
