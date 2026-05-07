import Foundation

internal protocol ActivityTickScheduler {
    func start(onTick: @escaping () -> Void)
    func stop()
}

internal final class TimerTickScheduler: ActivityTickScheduler {
    private let interval: TimeInterval
    private var timer: Timer?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    func start(onTick: @escaping () -> Void) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { _ in onTick() }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
