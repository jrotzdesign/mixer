import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String {
        let n = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(bytes: bytes, encoding: .ascii) ?? "")'" : ""
        return "\(what) failed: \(status)\(fourCC)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(what: what(), status: status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    var isValid: Bool { self != .unknown }

    func address(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(_ selector: AudioObjectPropertySelector, default value: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 qualifier: (UnsafeRawPointer, UInt32)? = nil) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            AudioObjectGetPropertyData(self, &addr, qualifier?.1 ?? 0, qualifier?.0, &size, ptr)
        }
        try check(status, "read \(selector.fourCC) on \(self)")
        return result
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value), "read \(selector.fourCC) on \(self)")
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    func readArray(_ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size), "size \(selector.fourCC)")
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &ids), "read \(selector.fourCC)")
        return ids
    }

    func write<T>(_ selector: AudioObjectPropertySelector, _ value: T,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var addr = address(selector, scope: scope)
        let status = withUnsafePointer(to: value) { ptr in
            AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        try check(status, "write \(selector.fourCC) on \(self)")
    }

    // MARK: System-level helpers

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID.unknown)
    }

    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        return try withUnsafePointer(to: &pidValue) { p in
            try AudioObjectID.system.read(kAudioHardwarePropertyTranslatePIDToProcessObject,
                                          default: AudioObjectID.unknown,
                                          qualifier: (UnsafeRawPointer(p), UInt32(MemoryLayout<pid_t>.size)))
        }
    }

    func deviceUID() throws -> String { try readString(kAudioDevicePropertyDeviceUID) }

    func tapFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }
}

extension AudioObjectPropertySelector {
    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(self)"
    }
}

/// A registered property listener; call `cancel()` to remove it.
final class ListenerToken {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = true

    fileprivate init(objectID: AudioObjectID, address: AudioObjectPropertyAddress,
                     queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }

    func cancel() {
        guard active else { return }
        active = false
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }

    deinit { cancel() }
}

extension AudioObjectID {
    /// Calls `handler` on the main queue whenever the property changes.
    func addListener(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     handler: @escaping @Sendable () -> Void) throws -> ListenerToken {
        var addr = address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(self, &addr, .main, block), "listen \(selector.fourCC) on \(self)")
        return ListenerToken(objectID: self, address: addr, queue: .main, block: block)
    }
}
