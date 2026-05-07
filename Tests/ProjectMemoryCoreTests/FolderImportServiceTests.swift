import XCTest
@testable import ProjectMemoryCore

final class FolderImportServiceTests: XCTestCase {
    func testImportFolderIndexesSupportedFilesAndTimelineEvents() throws {
        let rootURL = try makeFixtureDirectory()
        try write("Plan\nTODO: ship eval support.", to: rootURL.appendingPathComponent("plan.md"))
        try write("ignore", to: rootURL.appendingPathComponent("image.png"))
        let store = try MemoryStore.inMemory()

        let result = FolderImportService().importFolder(
            url: rootURL,
            projectName: "Eval Fixture",
            store: store
        )

        let payload = try result.get()
        let projects = try store.fetchProjects()
        let sources = try store.fetchSources(projectID: payload.projectID)
        let events = try store.fetchTimeline(projectID: payload.projectID)

        XCTAssertEqual(projects.map(\.name), ["Eval Fixture"])
        XCTAssertEqual(sources.map(\.title), ["plan.md"])
        XCTAssertEqual(sources.first?.extractedText, "Plan\nTODO: ship eval support.")
        XCTAssertEqual(events.filter { $0.kind == .sourceAdded }.count, 1)
        XCTAssertTrue(payload.warnings.isEmpty)
    }

    func testImportFolderReusesExistingSourceIDForSameProjectAndPath() throws {
        let rootURL = try makeFixtureDirectory()
        let planURL = rootURL.appendingPathComponent("plan.md")
        try write("First version", to: planURL)
        let store = try MemoryStore.inMemory()
        let service = FolderImportService()

        let firstProjectID = try service.importFolder(
            url: rootURL,
            projectName: "Eval Fixture",
            store: store
        ).get().projectID
        let firstSource = try XCTUnwrap(try store.fetchSources(projectID: firstProjectID).first)

        try write("Second version", to: planURL)
        let secondProjectID = try service.importFolder(
            url: rootURL,
            projectName: "Eval Fixture",
            store: store
        ).get().projectID
        let sources = try store.fetchSources(projectID: secondProjectID)

        XCTAssertEqual(firstProjectID, secondProjectID)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.id, firstSource.id)
        XCTAssertEqual(sources.first?.extractedText, "Second version")
    }

    func testImportFolderSanitizesInvisibleControlsBeforePersistingSource() throws {
        let rootURL = try makeFixtureDirectory()
        let watermarkedURL = rootURL.appendingPathComponent("安全\u{200B}隐私.md")
        try write("安全\u{200B}隐私\u{200C}产品\u{200D}需求\u{FEFF}文档", to: watermarkedURL)
        let store = try MemoryStore.inMemory()

        let projectID = try FolderImportService().importFolder(
            url: rootURL,
            projectName: "Watermark Fixture",
            store: store
        ).get().projectID
        let source = try XCTUnwrap(try store.fetchSources(projectID: projectID).first)

        XCTAssertEqual(source.title, "安全隐私.md")
        XCTAssertEqual(source.extractedText, "安全隐私产品需求文档")
    }

    private func makeFixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.data(using: .utf8)?.write(to: url)
    }
}
