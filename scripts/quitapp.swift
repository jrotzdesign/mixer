// Asks every running app with the given bundle ID to quit normally (like ⌘Q).
import AppKit
let id = CommandLine.arguments[1]
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
print("quitting \(apps.count) process(es) of \(id): \(apps.map { $0.terminate() })")
