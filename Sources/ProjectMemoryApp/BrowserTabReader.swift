import Foundation
import ProjectMemoryCore

internal protocol BrowserTabReader {
    func readActiveTab(bundleID: String) throws -> (title: String, url: String)
}

internal enum BrowserTabReaderError: LocalizedError, Equatable {
    case unsupportedBrowser
    case noActiveTab
    case osaFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedBrowser:
            return "当前 bundle ID 不在支持的浏览器列表中。"
        case .noActiveTab:
            return "无法读取当前浏览器标签页，请检查自动化权限。"
        case .osaFailed(let s):
            return "osascript 执行失败 (status=\(s))。"
        }
    }
}

internal final class OSABrowserTabReader: BrowserTabReader {
    private let attemptLog: AutomationAttemptLog

    init(attemptLog: AutomationAttemptLog) {
        self.attemptLog = attemptLog
    }

    func readActiveTab(bundleID: String) throws -> (title: String, url: String) {
        guard let dialect = SupportedBrowsers.dialect(for: bundleID) else {
            throw BrowserTabReaderError.unsupportedBrowser
        }

        let script: String
        switch dialect {
        case .safari:
            script = """
            tell application id "\(bundleID)"
                if not (exists front document) then return ""
                return (name of front document) & linefeed & (URL of front document)
            end tell
            """
        case .chromium:
            script = """
            tell application id "\(bundleID)"
                if not (exists front window) then return ""
                set activeTab to active tab of front window
                return (title of activeTab) & linefeed & (URL of activeTab)
            end tell
            """
        }

        do {
            let output = try runOSA(script)
            let lines = output
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard lines.count == 2,
                  !lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                attemptLog.recordFailure(bundleID: bundleID, reason: "no active tab")
                throw BrowserTabReaderError.noActiveTab
            }
            attemptLog.recordSuccess(bundleID: bundleID)
            return (
                title: lines[0].trimmingCharacters(in: .whitespacesAndNewlines),
                url: lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch let BrowserTabReaderError.osaFailed(status) {
            attemptLog.recordFailure(bundleID: bundleID, reason: "osascript failed status=\(status)")
            throw BrowserTabReaderError.osaFailed(status: status)
        } catch {
            attemptLog.recordFailure(bundleID: bundleID, reason: "\(error)")
            throw error
        }
    }

    private func runOSA(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BrowserTabReaderError.osaFailed(status: process.terminationStatus)
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
