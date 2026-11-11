import Foundation

/// One app's volume setting. `percent` is what the slider shows (0–150);
/// `gain` is the linear amplitude the audio path applies.
struct AppVolume: Codable, Equatable, Sendable {
    static let maxPercent = 150
    static let step = 5

    var percent: Int = 100
    var muted = false

    /// Squared taper so the slider feels even to the ear (50 % ≈ half as loud).
    var gain: Float {
        guard !muted else { return 0 }
        let x = Float(percent) / 100
        return x * x
    }

    /// Apps at 100 % and unmuted are left alone (no tap, no added latency).
    var needsChannel: Bool { percent != 100 || muted }

    func nudged(by delta: Int) -> AppVolume {
        var v = self
        v.percent = min(max(percent + delta, 0), Self.maxPercent)
        return v
    }
}
