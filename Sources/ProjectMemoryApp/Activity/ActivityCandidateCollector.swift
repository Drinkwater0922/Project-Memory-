import AppKit
import ApplicationServices
import Foundation
import ProjectMemoryCore

internal protocol ActivityCandidateCollecting {
    func collect(snapshot: FrontmostApplicationSnapshot, now: Date) -> ActivityCandidate
}

internal final class MacOSActivityCandidateCollector: ActivityCandidateCollecting {
    private let browserTabReader: BrowserTabReader

    init(browserTabReader: BrowserTabReader) {
        self.browserTabReader = browserTabReader
    }

    func collect(snapshot: FrontmostApplicationSnapshot, now: Date) -> ActivityCandidate {
        var windowTitle: String? = nil
        var browserURL: String? = nil

        if SupportedBrowsers.dialect(for: snapshot.bundleID) != nil {
            // Browser branch — title and URL bound. URL fail → both nil.
            if let tab = try? browserTabReader.readActiveTab(bundleID: snapshot.bundleID) {
                windowTitle = tab.title
                browserURL = tab.url
            }
        } else {
            // Non-browser branch — AX title best-effort.
            windowTitle = readFrontWindowTitle(for: snapshot.pid)
        }

        return ActivityCandidate(
            observedAt: now,
            bundleID: snapshot.bundleID,
            appName: TextSanitizer.stripInvisibleControls(snapshot.appName),
            windowTitle: windowTitle.map { TextSanitizer.stripInvisibleControls($0) },
            browserURL: browserURL.map { TextSanitizer.stripInvisibleControls($0) }
        )
    }

    private func readFrontWindowTitle(for pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused
        else {
            return nil
        }
        let windowElement = window as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String,
              !title.isEmpty
        else {
            return nil
        }
        return title
    }
}
