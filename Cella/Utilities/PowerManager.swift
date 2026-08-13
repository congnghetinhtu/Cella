import Foundation
import IOKit.ps

/// Monitors power source state (AC power vs battery) and exposes a 60fps flag.
@Observable
final class PowerManager {
    static let shared = PowerManager()

    /// When true, animations should run at 60fps. When false, 30fps.
    var isPluggedIn: Bool = true

    private var runLoopSource: CFRunLoopSource?

    private init() {
        updatePowerState()
        startMonitoring()
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func startMonitoring() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var notificationSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let ctx = context else { return }
            let manager = Unmanaged<PowerManager>.fromOpaque(ctx).takeUnretainedValue()
            manager.updatePowerState()
        }, context)

        if let source = notificationSource?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func updatePowerState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue() as? [String: Any]
        else {
            isPluggedIn = true
            return
        }

        if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            isPluggedIn = (powerSource == kIOPSACPowerValue)
        } else {
            isPluggedIn = true
        }
    }

    /// Target frames per second based on power state.
    var targetFPS: Double { isPluggedIn ? 60.0 : 30.0 }

    /// Timer interval for the target FPS.
    var frameInterval: TimeInterval { 1.0 / targetFPS }
}
