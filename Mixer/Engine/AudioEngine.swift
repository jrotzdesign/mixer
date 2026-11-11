import AppKit
import CoreAudio
import Observation

/// One row in the mixer.
struct AppRow: Identifiable, Equatable {
    /// The app key (bundle ID or `path:<executable>`).
    let id: String
    let name: String
    let bundleURL: URL?
    let pid: pid_t
    var volume: AppVolume
    var isPlaying: Bool
    var isPinned: Bool
}

/// Live numbers for one channel (diagnostics view).
struct ChannelDiagnostics: Identifiable, Equatable {
    let id: String
    let callbacks: UInt64
    let peak: Float
    let gain: Float
}

/// Owns every channel. Reconciles live audio processes against saved volumes
/// (via ChannelPlanner) and is the only thing the UI and shortcuts talk to.
@MainActor
@Observable
final class AudioEngine {
    private(set) var rows: [AppRow] = []
    private(set) var permission: AudioCapturePermission.Status = .unknown

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let resolver: AppResolver
    @ObservationIgnored private let live: Bool
    @ObservationIgnored private var monitor: ProcessMonitor?
    @ObservationIgnored private var planner = ChannelPlanner()
    @ObservationIgnored private var visibility = RowVisibility()
    @ObservationIgnored private var groups: [AppGroup] = []
    @ObservationIgnored private var channels: [String: Channel] = [:]
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored let log = MixerLog(name: "engine.log")

    /// Where channels play. Replaced by DeviceMonitor's value once it exists.
    @ObservationIgnored var outputUID: () -> String? = { try? AudioObjectID.defaultOutputDevice().deviceUID() }

    private static let retryDelay: TimeInterval = 5

    init(settings: SettingsStore, resolver: AppResolver, live: Bool = true) {
        self.settings = settings
        self.resolver = resolver
        self.live = live
    }

    // MARK: Lifecycle

    func start() {
        guard live, monitor == nil else { return }
        MixerCrashGuardInstall()
        let swept = OrphanSweep.run()
        permission = AudioCapturePermission.status
        log.write("engine start swept=\(swept) permission=\(permission.rawValue)")

        // Keep timers and hotkey handling prompt; App Nap stalled the spike's timer by 1.8 s.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Mixer routes app audio and responds to shortcuts")

        let monitor = ProcessMonitor(resolver: resolver)
        monitor.onChange = { [weak self] groups in self?.ingest(groups: groups, now: Date()) }
        self.monitor = monitor
        monitor.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        monitor?.stop()
        monitor = nil
        for channel in channels.values { channel.invalidate() }
        channels.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        log.write("engine shutdown")
    }

    func requestPermission() {
        AudioCapturePermission.request { [weak self] granted in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permission = granted ? .granted : AudioCapturePermission.status
                self.reconcile(now: Date())
            }
        }
    }

    // MARK: Volume control

    func volume(for key: String) -> AppVolume { settings.volume(for: key) }

    func setPercent(_ percent: Int, for key: String) {
        var v = settings.volume(for: key)
        v.percent = min(max(percent, 0), AppVolume.maxPercent)
        apply(v, to: key)
    }

    func setMuted(_ muted: Bool, for key: String) {
        var v = settings.volume(for: key)
        v.muted = muted
        apply(v, to: key)
    }

    @discardableResult
    func toggleMute(for key: String) -> AppVolume {
        var v = settings.volume(for: key)
        v.muted.toggle()
        apply(v, to: key)
        return v
    }

    @discardableResult
    func nudge(_ key: String, by delta: Int) -> AppVolume {
        let v = settings.volume(for: key).nudged(by: delta)
        apply(v, to: key)
        return v
    }

    func setPinned(_ key: String?) {
        settings.pinnedAppKey = key
        recomputeRows(now: Date())
    }

    /// Live channel first (the sound changes on the next buffer), then save and reconcile.
    private func apply(_ volume: AppVolume, to key: String) {
        channels[key]?.setGain(volume.gain)
        settings.setVolume(volume, for: key)
        recomputeRows(now: Date())
        reconcile(now: Date())
    }

    /// Raw monitor groups (debug dumps).
    var currentGroups: [AppGroup] { groups }

    /// Forces a fresh read of the process list (debug).
    func refreshProcesses() { monitor?.refresh() }

    var diagnostics: [ChannelDiagnostics] {
        channels.values
            .map { ChannelDiagnostics(id: $0.key, callbacks: $0.callbackCount, peak: $0.inputPeak, gain: $0.targetGain) }
            .sorted { $0.id < $1.id }
    }

    // MARK: Reconciliation

    /// New process snapshot from the monitor (or a test).
    func ingest(groups: [AppGroup], now: Date) {
        self.groups = groups
        recomputeRows(now: now)
        reconcile(now: now)
    }

    private func tick() {
        ticks += 1
        if ticks % 5 == 0 {
            let status = AudioCapturePermission.status
            if status != permission {
                log.write("permission changed \(permission.rawValue) → \(status.rawValue)")
                permission = status
            }
        }
        recomputeRows(now: Date())
        reconcile(now: Date())
    }

    private func recomputeRows(now: Date) {
        let byKey = Dictionary(groups.map { ($0.identity.key, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = settings.pinnedAppKey
        let newRows = visibility.visibleKeys(groups: groups, now: now).compactMap { key -> AppRow? in
            guard let g = byKey[key] else { return nil }
            return AppRow(id: key, name: g.identity.name, bundleURL: g.identity.bundleURL, pid: g.identity.ownerPID,
                          volume: settings.volume(for: key), isPlaying: g.isPlaying, isPinned: key == pinned)
        }
        if newRows != rows { rows = newRows }
    }

    private func reconcile(now: Date) {
        guard live else { return }
        let plan = planner.plan(groups: groups, volume: settings.volume(for:),
                                existing: channels.mapValues(\.processes),
                                permissionGranted: permission == .granted, now: now)
        for key in plan.destroy {
            channels.removeValue(forKey: key)?.invalidate()
            log.write("channel destroyed key=\(key)")
        }
        let byKey = Dictionary(groups.map { ($0.identity.key, $0) }, uniquingKeysWith: { a, _ in a })
        for key in plan.update {
            guard let group = byKey[key], let channel = channels[key] else { continue }
            do {
                try channel.updateProcesses(group.processObjects)
                log.write("channel updated key=\(key) procs=\(group.processObjects.count)")
            } catch {
                log.write("channel update failed key=\(key) error=\(error)")
            }
        }
        for key in plan.create {
            guard let group = byKey[key], let uid = outputUID() else { continue }
            if let failed = failedAt[key], now.timeIntervalSince(failed) < Self.retryDelay { continue }
            do {
                let channel = try Channel(key: key, processObjects: group.processObjects, outputUID: uid,
                                          gain: settings.volume(for: key).gain, visibleForDebug: Self.visibleForDebug)
                channels[key] = channel
                failedAt.removeValue(forKey: key)
                log.write("channel created key=\(key) procs=\(group.processObjects.count) playing=\(group.isPlaying)")
            } catch {
                failedAt[key] = now
                log.write("channel create failed key=\(key) error=\(error)")
            }
        }
    }

    /// Debug builds can publish Mixer's devices so they show in Audio MIDI Setup.
    static var visibleForDebug: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "debugVisibleDevices")
        #else
        false
        #endif
    }
}
