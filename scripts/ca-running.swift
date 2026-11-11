// Prints whether each visible aggregate device is running somewhere.
import CoreAudio
func ids(_ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &out); return out
}
func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 4; var v: UInt32 = 0
    let s = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v); return s == noErr ? v : 999
}
for d in ids(kAudioHardwarePropertyDevices) where u32(d, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate {
    print("aggregate \(d) runningSomewhere=\(u32(d, kAudioDevicePropertyDeviceIsRunningSomewhere))")
}
