import SwiftUI

@main
struct MixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Mixer", systemImage: "slider.vertical.3") {
            Text("Mixer — setup build")
            Divider()
            Button("Quit Mixer") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var spike: SpikeTap?
    private var monitor: ProcessMonitor?  // TEMP (Task 4 live check)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run hosted in this app; never touch live audio while they run.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if CommandLine.arguments.contains("--request-permission") {
            let log = MixerLog()
            log.write("permission_before=\(AudioCapturePermission.status.rawValue)")
            AudioCapturePermission.request { granted in
                log.write("permission_request_result=\(granted)")
            }
        }
        if CommandLine.arguments.contains("--list-processes") {  // TEMP (Task 4 live check)
            let log = MixerLog(name: "engine.log")
            let monitor = ProcessMonitor(resolver: AppResolver(source: SystemProcessInfo()))
            monitor.onChange = { groups in
                log.write("groups=\(groups.count)")
                for g in groups {
                    log.write("  \(g.identity.key) name=\(g.identity.name) owner=\(g.identity.ownerPID) procs=\(g.processObjects.count) playing=\(g.isPlaying)")
                }
            }
            monitor.start()
            self.monitor = monitor
        }
        if let i = CommandLine.arguments.firstIndex(of: "--channel-pid"), let pid = pid_t(CommandLine.arguments[i + 1]) {
            runChannelCheck(pid: pid)  // TEMP (Task 6 live check)
        }
        if let options = SpikeTap.Options(arguments: CommandLine.arguments) {
            let spike = SpikeTap(options: options)
            self.spike = spike
            spike.start()
        }
    }

    // TEMP (Task 6 live check): exercise Channel end to end and log to engine.log.
    private var checkChannel: Channel?
    private var checkTimer: Timer?
    private func runChannelCheck(pid: pid_t) {
        let args = CommandLine.arguments
        let log = MixerLog(name: "engine.log")
        let extraPID = args.firstIndex(of: "--extra-pid").flatMap { pid_t(args[$0 + 1]) }
        MixerCrashGuardInstall()
        log.write("sweep_destroyed=\(OrphanSweep.run()) permission=\(AudioCapturePermission.status.rawValue)")
        guard AudioCapturePermission.status == .granted else { log.write("error=no permission"); return }
        do {
            let obj = try AudioObjectID.processObject(forPID: pid)
            let uid = try AudioObjectID.defaultOutputDevice().deviceUID()
            let channel = try Channel(key: "check-\(pid)", processObjects: [obj], outputUID: uid, gain: 0.09,
                                      visibleForDebug: args.contains("--visible"))
            checkChannel = channel
            log.write("created tap=\(channel.tapObjectID) tracked=\(MixerCrashGuardTrackedCount())")
            var t = 0
            checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    t += 1
                    log.write(String(format: "t=%.1f cb=%llu peak=%.3f gain=%.2f", Double(t) / 2,
                                     channel.callbackCount, channel.inputPeak, channel.targetGain))
                    switch t {
                    case 6: channel.setGain(0); log.write("set gain 0 (mute)")
                    case 12: channel.setGain(1); log.write("set gain 1")
                    case 16:
                        if let extra = extraPID,
                           let obj2 = try? AudioObjectID.processObject(forPID: extra) {
                            let before = channel.tapObjectID
                            do {
                                try channel.updateProcesses([obj, obj2].sorted())
                                log.write("update in_place=\(before == channel.tapObjectID) tap=\(channel.tapObjectID)")
                            } catch { log.write("update error=\(error)") }
                        }
                    case 20:
                        if args.contains("--abort") { log.write("aborting"); abort() }
                        channel.invalidate()
                        log.write("invalidated tracked=\(MixerCrashGuardTrackedCount())")
                        self?.checkTimer?.invalidate()
                    default: break
                    }
                }
            }
        } catch {
            log.write("error=\(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        spike?.stop()
    }
}
