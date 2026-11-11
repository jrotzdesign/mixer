import AppKit
import CoreAudio

/// A process Core Audio knows about (it has set up audio, maybe not playing yet).
struct AudioProcess: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let isRunningOutput: Bool
}

/// All of one app's audio processes (the app plus its helpers).
struct AppGroup: Equatable, Sendable {
    let identity: AppIdentity
    /// Sorted, so equality means "same process set".
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

/// Watches Core Audio's process list and each process's "is playing" flag,
/// and publishes processes grouped by owning app.
@MainActor
final class ProcessMonitor {
    var onChange: (([AppGroup]) -> Void)?
    private(set) var groups: [AppGroup] = []

    private let resolver: AppResolver
    private var listToken: ListenerToken?
    private var outputTokens: [AudioObjectID: ListenerToken] = [:]
    private var terminateObserver: NSObjectProtocol?

    init(resolver: AppResolver) {
        self.resolver = resolver
    }

    func start() {
        guard listToken == nil else { return }
        listToken = try? AudioObjectID.system.addListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        listToken?.cancel()
        listToken = nil
        outputTokens.values.forEach { $0.cancel() }
        outputTokens.removeAll()
        if let terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    /// Re-reads every process and regroups. Cheap: a few dozen property reads.
    func refresh() {
        let objects = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)) ?? []
        let processes: [AudioProcess] = objects.compactMap { obj in
            guard let pid = try? obj.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0 else { return nil }
            let running = ((try? obj.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
            return AudioProcess(objectID: obj, pid: pid, isRunningOutput: running)
        }
        syncOutputListeners(Set(processes.map(\.objectID)))

        var byKey: [String: AppGroup] = [:]
        for process in processes {
            guard let identity = resolver.resolve(pid: process.pid) else { continue }
            var group = byKey[identity.key] ?? AppGroup(identity: identity, processObjects: [], isPlaying: false)
            group.processObjects.append(process.objectID)
            group.isPlaying = group.isPlaying || process.isRunningOutput
            byKey[identity.key] = group
        }
        let newGroups = byKey.values
            .map { var g = $0; g.processObjects.sort(); return g }
            .sorted { $0.identity.key < $1.identity.key }

        guard newGroups != groups else { return }
        groups = newGroups
        onChange?(newGroups)
    }

    private func syncOutputListeners(_ current: Set<AudioObjectID>) {
        for (obj, token) in outputTokens where !current.contains(obj) {
            token.cancel()
            outputTokens.removeValue(forKey: obj)
        }
        for obj in current where outputTokens[obj] == nil {
            outputTokens[obj] = try? obj.addListener(kAudioProcessPropertyIsRunningOutput) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
}
