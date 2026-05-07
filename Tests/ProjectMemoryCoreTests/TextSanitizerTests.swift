import XCTest
@testable import ProjectMemoryCore

final class TextSanitizerTests: XCTestCase {
    func testStripInvisibleControlsRemovesCommonZeroWidthScalars() {
        let raw = "A\u{200D}B\u{200C}C\u{200B}D\u{FEFF}E\u{200F}F"

        XCTAssertEqual(TextSanitizer.stripInvisibleControls(raw), "ABCDEF")
    }

    func testStripInvisibleControlsKeepsNewlineTabVisibleTextAndEmoji() {
        let raw = "中文\tEnglish\n🙂\u{0007}"

        XCTAssertEqual(TextSanitizer.stripInvisibleControls(raw), "中文\tEnglish\n🙂")
    }

    func testStripInvisibleControlsRemovesFeishuStyleWatermarkScalars() {
        let raw = "安全\u{200B}隐私\u{200C}产品\u{200D}需求\u{FEFF}文档 - 飞书云文档"

        XCTAssertEqual(
            TextSanitizer.stripInvisibleControls(raw),
            "安全隐私产品需求文档 - 飞书云文档"
        )
    }
}
