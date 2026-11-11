import AudioToolbox
import CoreAudio
import Foundation

/// One adjusted app's audio route: a muted-when-tapped process tap over all
/// the app's processes, a private aggregate device (tap in, current output
/// out), and the C IOProc that applies gain (PLAN §5.3–5.4).
///
/// Call `invalidate()` before dropping a Channel; it owns Core Audio objects
/// and a C state block that must outlive its IOProc.
@MainActor
final class Channel {
    let key: String
    private(set) var outputUID: String

    private let isPrivate: Bool
    private var tapDescription: CATapDescription
    private var tapID = AudioObjectID.unknown
    private var route: Route?

    /// An aggregate device with its running IOProc and gain state.
    private struct Route {
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        let state: UnsafeMutablePointer<MixerChannelState>
    }

    init(key: String, processObjects: [AudioObjectID], outputUID: String, gain: Float,
         visibleForDebug: Bool = false) throws {
        self.key = key
        self.outputUID = outputUID
        self.isPrivate = !visibleForDebug
        tapDescription = Self.makeDescription(key: key, processes: processObjects, isPrivate: !visibleForDebug)
        tapID = try Self.createTap(tapDescription)
        do {
            route = try Self.makeRoute(tapUUID: tapDescription.uuid, outputUID: outputUID, key: key,
                                       isPrivate: isPrivate, gain: gain)
        } catch {
            Self.destroyTap(tapID)
            tapID = .unknown
            throw error
        }
    }

    // MARK: Control

    func setGain(_ gain: Float) {
        guard let route else { return }
        MixerChannelStateSetGain(route.state, gain)
    }

    var callbackCount: UInt64 { route.map { MixerChannelStateGetCallbackCount($0.state) } ?? 0 }
    var inputPeak: Float { route.map { MixerChannelStateGetInputPeak($0.state) } ?? 0 }
    var tapObjectID: AudioObjectID { tapID }
    var targetGain: Float { route.map { MixerChannelStateGetTargetGain($0.state) } ?? 0 }

    /// A helper process joined or left: edit the tap in place, or rebuild make-before-break.
    func updateProcesses(_ objects: [AudioObjectID]) throws {
        let edited = Self.makeDescription(key: key, processes: objects, isPrivate: isPrivate)
        edited.uuid = tapDescription.uuid
        // The property value is a CATapDescription* (an object reference).
        var ref = Unmanaged.passUnretained(edited).toOpaque()
        var addr = tapID.address(kAudioTapPropertyDescription)
        let status = AudioObjectSetPropertyData(tapID, &addr, 0, nil,
                                                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &ref)
        if status == noErr {
            tapDescription = edited
            return
        }
        try rebuild(processes: objects, outputUID: outputUID)
    }

    /// The default output changed: start a route on the new device with the same
    /// tap, then retire the old one. Falls back to a full rebuild.
    func move(toOutputUID uid: String) throws {
        guard uid != outputUID, let old = route else { return }
        let gain = MixerChannelStateGetTargetGain(old.state)
        if let fresh = try? Self.makeRoute(tapUUID: tapDescription.uuid, outputUID: uid, key: key,
                                           isPrivate: isPrivate, gain: gain) {
            route = fresh
            outputUID = uid
            Self.destroyRoute(old)
            return
        }
        try rebuild(processes: tapDescription.processes, outputUID: uid)
    }

    /// Full make-before-break rebuild: new tap + route running before the old ones go.
    func rebuild(processes: [AudioObjectID], outputUID uid: String) throws {
        let gain = route.map { MixerChannelStateGetTargetGain($0.state) } ?? 1
        let desc = Self.makeDescription(key: key, processes: processes, isPrivate: isPrivate)
        let newTap = try Self.createTap(desc)
        let newRoute: Route
        do {
            newRoute = try Self.makeRoute(tapUUID: desc.uuid, outputUID: uid, key: key, isPrivate: isPrivate, gain: gain)
        } catch {
            Self.destroyTap(newTap)
            throw error
        }
        let oldRoute = route, oldTap = tapID
        route = newRoute
        tapID = newTap
        tapDescription = desc
        outputUID = uid
        if let oldRoute { Self.destroyRoute(oldRoute) }
        Self.destroyTap(oldTap)
    }

    /// Stop → destroy IOProc → destroy aggregate → destroy tap. Safe to call twice.
    func invalidate() {
        if let route { Self.destroyRoute(route) }
        route = nil
        Self.destroyTap(tapID)
        tapID = .unknown
    }

    // MARK: Core Audio plumbing

    private static func makeDescription(key: String, processes: [AudioObjectID], isPrivate: Bool) -> CATapDescription {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.name = "Mixer-\(key)"
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = isPrivate
        return desc
    }

    private static func createTap(_ desc: CATapDescription) throws -> AudioObjectID {
        var tap = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(desc, &tap), "AudioHardwareCreateProcessTap")
        MixerCrashGuardTrack(tap, 1)
        return tap
    }

    private static func destroyTap(_ tap: AudioObjectID) {
        guard tap.isValid else { return }
        AudioHardwareDestroyProcessTap(tap)
        MixerCrashGuardUntrack(tap)
    }

    private static func makeRoute(tapUUID: UUID, outputUID: String, key: String,
                                  isPrivate: Bool, gain: Float) throws -> Route {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer-\(key)",
            kAudioAggregateDeviceUIDKey: "com.jrortizdesign.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: isPrivate,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: isPrivate,  // the key requires a private aggregate
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
                  "AudioHardwareCreateAggregateDevice")
        MixerCrashGuardTrack(aggregate, 0)

        let state = UnsafeMutablePointer<MixerChannelState>.allocate(capacity: 1)
        MixerChannelStateInit(state, gain)
        try? aggregate.write(kAudioDevicePropertyBufferFrameSize, UInt32(256))

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(aggregate, MixerIOProc, UnsafeMutableRawPointer(state), &procID)
        if status == noErr, let procID {
            status = AudioDeviceStart(aggregate, procID)
            if status == noErr {
                return Route(aggregateID: aggregate, procID: procID, state: state)
            }
            AudioDeviceDestroyIOProcID(aggregate, procID)
        }
        AudioHardwareDestroyAggregateDevice(aggregate)
        MixerCrashGuardUntrack(aggregate)
        state.deallocate()
        throw CoreAudioError(what: "start IOProc", status: status)
    }

    private static func destroyRoute(_ route: Route) {
        AudioDeviceStop(route.aggregateID, route.procID)
        AudioDeviceDestroyIOProcID(route.aggregateID, route.procID)
        AudioHardwareDestroyAggregateDevice(route.aggregateID)
        MixerCrashGuardUntrack(route.aggregateID)
        route.state.deallocate()  // only after the IOProc is gone
    }
}
