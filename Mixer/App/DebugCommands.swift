#if DEBUG
import Foundation

/// Debug-only remote control so live checks can drive the engine from scripts
/// (`scripts/mixerctl`). Listens for the distributed notification
/// `com.jrortizdesign.mixer.debug` whose object is a command string:
///   set <key> <percent> | mute <key> <0|1> | dump | crash
/// `dump` writes rows and channels to ~/Library/Logs/Mixer/engine.log.
@MainActor
final class DebugCommands {
    static let name = Notification.Name("com.jrortizdesign.mixer.debug")
    private let engine: AudioEngine
    private var observer: NSObjectProtocol?

    init(engine: AudioEngine) {
        self.engine = engine
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.name, object: nil, queue: .main
        ) { [weak self] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.run(command) }
        }
    }

    private func run(_ command: String) {
        let parts = command.split(separator: " ").map(String.init)
        guard let verb = parts.first else { return }
        engine.log.write("debug command: \(command)")
        switch verb {
        case "set" where parts.count == 3:
            if let p = Int(parts[2]) { engine.setPercent(p, for: parts[1]) }
        case "mute" where parts.count == 3:
            engine.setMuted(parts[2] == "1", for: parts[1])
        case "dump":
            engine.log.write("dump rows=\(engine.rows.count) channels=\(engine.diagnostics.count) tracked=\(MixerCrashGuardTrackedCount()) permission=\(engine.permission.rawValue)")
            for r in engine.rows {
                engine.log.write("  row \(r.id) name=\(r.name) pct=\(r.volume.percent) muted=\(r.volume.muted) playing=\(r.isPlaying)")
            }
            for c in engine.diagnostics {
                engine.log.write(String(format: "  channel %@ callbacks=%llu peak=%.3f gain=%.3f", c.id, c.callbacks, c.peak, c.gain))
            }
        case "groups":
            for g in engine.currentGroups {
                engine.log.write("  group \(g.identity.key) owner=\(g.identity.ownerPID) procs=\(g.processObjects) playing=\(g.isPlaying)")
            }
        case "refresh":
            engine.refreshProcesses()
        case "crash":
            abort()
        default:
            engine.log.write("debug command not understood")
        }
    }
}
#endif
