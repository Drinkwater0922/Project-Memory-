import AppKit
import CoreGraphics
import Foundation

internal protocol IdleStateProvider {
    func secondsSinceLastUserInput() -> TimeInterval
}

internal protocol ScreenLockStateProvider {
    var isScreenLocked: Bool { get }
}

internal struct FrontmostApplicationSnapshot: Equatable {
    let bundleID: String
    let appName: String
    let pid: pid_t
}

internal protocol FrontmostAppProvider {
    func snapshot() -> FrontmostApplicationSnapshot?
}

internal final class CGEventIdleStateProvider: IdleStateProvider {
    func secondsSinceLastUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
    }
}

internal final class CGSessionScreenLockStateProvider: ScreenLockStateProvider {
    var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return false
    }
}

internal final class WorkspaceFrontmostAppProvider: FrontmostAppProvider {
    func snapshot() -> FrontmostApplicationSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            return nil
        }
        let appName = app.localizedName
            ?? app.bundleURL?.lastPathComponent
            ?? bundleID
        return FrontmostApplicationSnapshot(
            bundleID: bundleID,
            appName: appName,
            pid: app.processIdentifier
        )
    }
}
