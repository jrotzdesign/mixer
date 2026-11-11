import Foundation

/// "System Audio Recording Only" permission (TCC service kTCCServiceAudioCapture).
///
/// There is no public API to check or request this permission, so this uses the
/// TCC preflight/request functions via dlopen, the same pattern as insidegui/AudioCap.
/// If the functions are missing, status is `.unknown` and the first tap triggers
/// the system prompt instead.
enum AudioCapturePermission {
    enum Status: String { case granted, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(sym, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet. Completion runs on the main queue.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let request = unsafeBitCast(sym, to: RequestFn.self)
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
