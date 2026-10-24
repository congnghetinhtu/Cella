import Combine
import Foundation
import QuartzCore

/// Main RunLoop timer that publishes frame timestamps.
/// Fires before rendering — no cross-thread latency like CVDisplayLink.
final class DisplayLink {
    static let shared = DisplayLink()

    let framePublisher = PassthroughSubject<CFTimeInterval, Never>()

    private var timer: Timer?
    private var running = false

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.framePublisher.send(CACurrentMediaTime())
        }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    deinit {
        stop()
    }
}
