// Lists Core Audio process objects: pid, running output/input, bundle ID.
import CoreAudio
func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: T) -> T {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size); var out = v
    _ = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }; return out
}
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
let filter = CommandLine.arguments.count > 1 ? Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) }) : nil
for id in ids {
    let pid = get(id, kAudioProcessPropertyPID, pid_t(0))
    if let filter, !filter.contains(pid) { continue }
    var ba = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var bs = UInt32(MemoryLayout<CFString?>.size); var b: Unmanaged<CFString>?
    let bundle = AudioObjectGetPropertyData(id, &ba, 0, nil, &bs, &b) == noErr ? (b?.takeRetainedValue() as String? ?? "") : ""
    print("obj=\(id) pid=\(pid) out=\(get(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) in=\(get(id, kAudioProcessPropertyIsRunningInput, UInt32(0))) bundle=\(bundle)")
}
