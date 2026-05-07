@testable import ProjectMemoryApp

final class StubBrowserTabReader: BrowserTabReader {
    var result: Result<(title: String, url: String), Error>
    init(result: Result<(title: String, url: String), Error>) { self.result = result }
    func readActiveTab(bundleID: String) throws -> (title: String, url: String) {
        try result.get()
    }
}
