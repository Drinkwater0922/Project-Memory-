import XCTest
@testable import ProjectMemoryCore

final class ProjectResolverTests: XCTestCase {
    func testResolverUsesProjectRootPath() {
        let project = Project(name: "Alpha", rootPath: "/Users/me/work/alpha")
        let resolver = ProjectResolver(projects: [project])

        let resolved = resolver.resolve(path: "/Users/me/work/alpha/notes/plan.md")

        XCTAssertEqual(resolved, project.id)
    }

    func testResolverReturnsNilForUnmatchedPath() {
        let project = Project(name: "Alpha", rootPath: "/Users/me/work/alpha")
        let resolver = ProjectResolver(projects: [project])

        XCTAssertNil(resolver.resolve(path: "/Users/me/other/beta.md"))
    }

    func testResolverMatchesExactRootPath() {
        let project = Project(name: "Alpha", rootPath: "/Users/me/work/alpha")
        let resolver = ProjectResolver(projects: [project])

        XCTAssertEqual(resolver.resolve(path: "/Users/me/work/alpha"), project.id)
    }

    func testResolverDoesNotMatchSiblingPrefix() {
        let project = Project(name: "Alpha", rootPath: "/Users/me/work/alpha")
        let resolver = ProjectResolver(projects: [project])

        XCTAssertNil(resolver.resolve(path: "/Users/me/work/alpha-other/plan.md"))
    }

    func testResolverUsesLongestStandardizedRoot() {
        let parent = Project(name: "Parent", rootPath: "/Users/me/work/long/../alpha")
        let child = Project(name: "Child", rootPath: "/Users/me/work/alpha/child")
        let resolver = ProjectResolver(projects: [parent, child])

        let resolved = resolver.resolve(path: "/Users/me/work/alpha/child/plan.md")

        XCTAssertEqual(resolved, child.id)
    }
}
