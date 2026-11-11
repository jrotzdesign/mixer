// Lists every aggregate device and process tap visible to this process.
// Private objects owned by other processes are not visible here by design.
import CoreAudio
import Foundation

func ids(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &out)
    return out
}
func str(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var v: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return "?" }
    return v.takeRetainedValue() as String
}
func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 4; var v: UInt32 = 0
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v); return v
}
let aggregates = ids(kAudioHardwarePropertyDevices).filter { u32($0, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate }
let taps = ids(kAudioHardwarePropertyTapList)
print("aggregates=\(aggregates.count) taps=\(taps.count)")
for d in aggregates { print("  aggregate \(d): \(str(d, kAudioObjectPropertyName))") }
for t in taps { print("  tap \(t): \(str(t, kAudioObjectPropertyName))") }
