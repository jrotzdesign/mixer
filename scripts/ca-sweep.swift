// Destroys visible aggregate devices and process taps whose name starts with "Mixer-".
// Prototype of the engine's launch-time orphan sweep.
import CoreAudio
func ids(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &out); return out
}
func name(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size); var v: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return "" }
    return v.takeRetainedValue() as String
}
for d in ids(kAudioHardwarePropertyDevices) where name(d).hasPrefix("Mixer-") {
    print("destroy aggregate \(d) \(name(d)): \(AudioHardwareDestroyAggregateDevice(d))")
}
for t in ids(kAudioHardwarePropertyTapList) where name(t).hasPrefix("Mixer-") {
    print("destroy tap \(t) \(name(t)): \(AudioHardwareDestroyProcessTap(t))")
}
