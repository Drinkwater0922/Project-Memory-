import AppKit
import Foundation
import ProjectMemoryCore

struct AutoWebCaptureResult: Equatable {
    var title: String
    var url: String
    var browserName: String
    var capturedAt: Date

    var textSnapshot: String {
        """
        自动网页捕获
        浏览器：\(browserName)
        标题：\(title)
        URL：\(url)
        捕获时间：\(ISO8601DateFormatter().string(from: capturedAt))
        """
    }
}

enum AutoWebCaptureError: LocalizedError {
    case noSupportedBrowser
    case readerFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noSupportedBrowser:
            return "当前前台应用不是受支持的浏览器。"
        case .readerFailed(let underlying):
            return (underlying as? LocalizedError)?.errorDescription
                ?? "无法读取当前浏览器标签页。"
        }
    }
}

struct AutoWebCaptureService {
    private let reader: BrowserTabReader

    init(reader: BrowserTabReader) {
        self.reader = reader
    }

    func captureActiveBrowser() throws -> AutoWebCaptureResult {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              SupportedBrowsers.dialect(for: bundleID) != nil
        else {
            throw AutoWebCaptureError.noSupportedBrowser
        }

        let displayName = app.localizedName
            ?? app.bundleURL?.lastPathComponent
            ?? "Browser"

        do {
            let tab = try reader.readActiveTab(bundleID: bundleID)
            return AutoWebCaptureResult(
                title: tab.title,
                url: tab.url,
                browserName: displayName,
                capturedAt: Date()
            )
        } catch {
            throw AutoWebCaptureError.readerFailed(error)
        }
    }
}
