import SwiftUI

@main
struct MixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Mixer", systemImage: "slider.vertical.3") {
            // Placeholder until the real popover (Task 8).
            ForEach(AppModel.shared.engine.rows) { row in
                Text("\(row.name) — \(row.volume.muted ? "muted" : "\(row.volume.percent)%")")
            }
            Divider()
            Button("Quit Mixer") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// App-wide objects. Created on first use; the engine only touches live audio after `start()`.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings = SettingsStore()
    let engine: AudioEngine

    private init() {
        engine = AudioEngine(settings: settings, resolver: AppResolver(source: SystemProcessInfo()))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var spike: SpikeTap?
    #if DEBUG
    private var debugCommands: DebugCommands?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run hosted in this app; never touch live audio while they run.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        let args = CommandLine.arguments

        // Test harness modes used by scripts/crashtest.sh (phase 1).
        if args.contains("--request-permission") {
            let log = MixerLog()
            log.write("permission_before=\(AudioCapturePermission.status.rawValue)")
            AudioCapturePermission.request { granted in log.write("permission_request_result=\(granted)") }
            return
        }
        if let options = SpikeTap.Options(arguments: args) {
            let spike = SpikeTap(options: options)
            self.spike = spike
            spike.start()
            return
        }

        AppModel.shared.engine.start()
        #if DEBUG
        debugCommands = DebugCommands(engine: AppModel.shared.engine)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        spike?.stop()
        AppModel.shared.engine.shutdown()
    }
}
