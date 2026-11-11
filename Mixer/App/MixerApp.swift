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
        if let options = SpikeTap.Options(arguments: CommandLine.arguments) {
            let spike = SpikeTap(options: options)
            self.spike = spike
            spike.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        spike?.stop()
    }
}
