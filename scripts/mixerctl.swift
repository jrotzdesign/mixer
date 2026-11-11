// Sends a debug command to a running Debug build of Mixer.
//   mixerctl set <key> <percent> | mute <key> <0|1> | dump | crash
import Foundation
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.jrortizdesign.mixer.debug"), object: command, userInfo: nil, deliverImmediately: true)
