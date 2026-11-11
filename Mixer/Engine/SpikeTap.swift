import AppKit
import AudioToolbox
import CoreAudio

/// Phase-1 test harness: tap one process at a fixed gain and route it to the
/// default output. Used to prove the core recipe and crash cleanup before the
/// real engine exists. Launch with:
///   open -n Mixer.app --args --spike-pid <pid> [--spike-gain 0.3] [--spike-public]
@MainActor
final class SpikeTap {
    struct Options {
        var pid: pid_t
        var gain: Float = 0.3
        var isPrivate = true
        /// Observer mode: an unmuted global tap that only measures the system mix (outputs silence).
        var observe = false

        init?(arguments: [String]) {
            func value(_ flag: String) -> String? {
                guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
                return arguments[i + 1]
            }
            observe = arguments.contains("--observe")
            guard let p = value("--spike-pid").flatMap({ pid_t($0) }) ?? (observe ? 0 : nil) else { return nil }
            pid = p
            if observe { gain = 0 }
            if let g = value("--spike-gain").flatMap({ Float($0) }) { gain = g }
            isPrivate = !arguments.contains("--spike-public")
        }
    }

    private let options: Options
    private let log: SpikeLog
    private let state: UnsafeMutablePointer<MixerChannelState>
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var timer: Timer?

    init(options: Options) {
        self.options = options
        self.log = SpikeLog(name: options.observe ? "observe.log" : "spike.log")
        state = .allocate(capacity: 1)
        MixerChannelStateInit(state, options.gain)
    }

    func start() {
        log.write("mixer_pid=\(getpid()) target_pid=\(options.pid) gain=\(options.gain) private=\(options.isPrivate)")
        let status = AudioCapturePermission.status
        log.write("permission=\(status.rawValue)")
        switch status {
        case .granted:
            build()
        case .denied, .unknown:
            // Never create a muting tap before permission is confirmed: a tap made
            // without it can deliver silence, which would silence the target app.
            AudioCapturePermission.request { [weak self] granted in
                MainActor.assumeIsolated {
                    self?.log.write("permission_request_result=\(granted)")
                    if granted { self?.build() }
                }
            }
        }
    }

    private func build() {
        do {
            let desc: CATapDescription
            if options.observe {
                desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                desc.muteBehavior = .unmuted
            } else {
                let processObject = try AudioObjectID.processObject(forPID: options.pid)
                guard processObject.isValid else {
                    log.write("error=no audio process object for pid \(options.pid)")
                    return
                }
                desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
                desc.muteBehavior = .mutedWhenTapped
            }
            desc.uuid = UUID()
            desc.name = "Mixer-spike-\(options.pid)"
            desc.isPrivate = options.isPrivate
            try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")
            log.write("tap_id=\(tapID)")

            let format = try tapID.tapFormat()
            log.write("tap_format sr=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) flags=\(format.mFormatFlags)")

            let output = try AudioObjectID.defaultOutputDevice()
            let outputUID = try output.deviceUID()
            log.write("output_device=\(output) uid=\(outputUID)")

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Mixer-spike-\(options.pid)",
                kAudioAggregateDeviceUIDKey: "com.jrortizdesign.mixer.spike.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: options.isPrivate,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                      "AudioHardwareCreateAggregateDevice")
            log.write("aggregate_id=\(aggregateID)")

            do {
                try aggregateID.write(kAudioDevicePropertyBufferFrameSize, UInt32(256))
            } catch {
                log.write("warn=\(error)")
            }
            let frames = (try? aggregateID.read(kAudioDevicePropertyBufferFrameSize, default: UInt32(0))) ?? 0
            log.write("buffer_frames=\(frames)")

            try check(AudioDeviceCreateIOProcID(aggregateID, MixerIOProc, UnsafeMutableRawPointer(state), &procID),
                      "AudioDeviceCreateIOProcID")
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
            log.write("running=true")

            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        } catch {
            log.write("error=\(error)")
            stop()
        }
    }

    private func report() {
        let callbacks = MixerChannelStateGetCallbackCount(state)
        let peak = MixerChannelStateGetInputPeak(state)
        log.write(String(format: "callbacks=%llu input_peak=%.4f", callbacks, peak))
    }

    /// Clean teardown, in AudioCap's order: stop → destroy IOProc → destroy aggregate → destroy tap.
    func stop() {
        timer?.invalidate()
        timer = nil
        if aggregateID.isValid {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
            procID = nil
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        log.write("stopped=clean")
    }
}

/// Appends timestamped lines to ~/Library/Logs/Mixer/spike.log.
struct SpikeLog {
    let url: URL

    init(name: String = "spike.log") {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mixer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
    }

    func write(_ line: String) {
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
