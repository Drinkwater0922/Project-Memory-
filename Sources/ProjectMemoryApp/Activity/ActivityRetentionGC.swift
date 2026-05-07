import Foundation
import ProjectMemoryCore

internal final class ActivityRetentionGC {
    static let defaultRetentionDays = 30

    private let store: MemoryStore
    private let retentionDays: Int
    private let now: () -> Date

    init(
        store: MemoryStore,
        retentionDays: Int = ActivityRetentionGC.defaultRetentionDays,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.retentionDays = retentionDays
        self.now = now
    }

    /// Synchronously delete frames older than retention window. Safe to call from main actor.
    func runOnce() {
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        try? store.deleteActivityFrames(beforeDate: cutoff)
    }
}
