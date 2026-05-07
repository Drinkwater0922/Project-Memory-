import XCTest
@testable import ProjectMemoryCore

final class ParserTests: XCTestCase {
    func testMarkdownParserKeepsReadableText() throws {
        let parser = SourceParser()
        let result = try parser.extractText(
            from: "Title\n\n- Ship MVP\n- Review sources".data(using: .utf8)!,
            fileExtension: "md"
        )

        XCTAssertTrue(result.contains("Ship MVP"))
        XCTAssertTrue(result.contains("Review sources"))
    }

    func testHTMLParserRemovesTagsScriptsStylesAndDecodesEntities() throws {
        let parser = SourceParser()
        let html = """
        <html>
            <head>
                <style>.hidden { display: none; }</style>
                <script>window.secret = "do not index";</script>
            </head>
            <body>
                <h1>Article&nbsp;Title</h1>
                <p>Useful &amp; relevant context</p>
            </body>
        </html>
        """

        let result = try parser.extractText(
            from: html.data(using: .utf8)!,
            fileExtension: "html"
        )

        XCTAssertTrue(result.contains("Article Title"))
        XCTAssertTrue(result.contains("Useful & relevant context"))
        XCTAssertFalse(result.contains("<p>"))
        XCTAssertFalse(result.contains("window.secret"))
        XCTAssertFalse(result.contains("display: none"))
    }

    func testUnsupportedParserExtensionThrows() throws {
        let parser = SourceParser()

        XCTAssertThrowsError(
            try parser.extractText(from: Data("image".utf8), fileExtension: "png")
        ) { error in
            XCTAssertEqual(error as? ParserError, .unsupported("png"))
        }
    }

    func testInvalidUTF8ThrowsUnreadable() {
        let parser = SourceParser()

        XCTAssertThrowsError(
            try parser.extractText(from: Data([0xFF, 0xFE, 0xFD]), fileExtension: "md")
        ) { error in
            XCTAssertEqual(error as? ParserError, .unreadable)
        }
    }

    func testScannerFindsSupportedFilesAndIgnoresUnsupportedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try "hello".write(to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "ignore".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)

        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "plain".write(to: nested.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "web".write(to: nested.appendingPathComponent("capture.HTML"), atomically: true, encoding: .utf8)

        let hidden = root.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "hidden".write(to: hidden.appendingPathComponent("secret.md"), atomically: true, encoding: .utf8)

        let package = root.appendingPathComponent("Widget.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "package".write(to: package.appendingPathComponent("PackageNote.md"), atomically: true, encoding: .utf8)

        let scanner = SourceScanner()
        let files = try scanner.scan(root: root)

        XCTAssertEqual(files.map(\.lastPathComponent), ["capture.HTML", "readme.txt", "note.md"])
    }

    func testScannerMapsSourceKinds() {
        let scanner = SourceScanner()

        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/plan.md")), .markdown)
        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/notes.markdown")), .markdown)
        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/plain.txt")), .text)
        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/file.pdf")), .pdf)
        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/page.htm")), .html)
        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/page.html")), .html)
        XCTAssertEqual(scanner.kind(for: URL(fileURLWithPath: "/tmp/image.png")), .unsupported)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
