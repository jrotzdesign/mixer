import CoreAudio

/// Destroys visible Mixer taps and aggregate devices left over from a
/// previous run (PLAN §5.6 layer 4). Private objects die with their process;
/// this catches the debug-visible ones and anything unexpected.
enum OrphanSweep {
    static let prefix = "Mixer-"

    @discardableResult
    static func run() -> Int {
        var destroyed = 0
        let devices = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)) ?? []
        for device in devices where name(of: device).hasPrefix(prefix) {
            if AudioHardwareDestroyAggregateDevice(device) == noErr { destroyed += 1 }
        }
        let taps = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyTapList)) ?? []
        for tap in taps where name(of: tap).hasPrefix(prefix) {
            if AudioHardwareDestroyProcessTap(tap) == noErr { destroyed += 1 }
        }
        return destroyed
    }

    private static func name(of object: AudioObjectID) -> String {
        (try? object.readString(kAudioObjectPropertyName)) ?? ""
    }
}
