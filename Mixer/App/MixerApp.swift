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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--request-permission") {
            let log = SpikeLog()
            log.write("permission_before=\(AudioCapturePermission.status.rawValue)")
            AudioCapturePermission.request { granted in
                log.write("permission_request_result=\(granted)")
            }
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
