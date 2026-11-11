import AppKit
import Darwin

/// Real process facts from AppKit, libproc, sysctl, and the private
/// responsibility API (the one Activity Monitor uses for XPC helpers).
final class SystemProcessInfo: ProcessInfoSource {
    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid`, looked up once; nil if missing.
    private static let responsibility: ResponsibilityFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    func runningApp(pid: pid_t) -> RunningAppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let name = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? executablePath(pid: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Process \(pid)"
        return RunningAppInfo(pid: pid, bundleID: app.bundleIdentifier, name: name,
                              bundleURL: app.bundleURL, isRegular: app.activationPolicy == .regular)
    }

    func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = Self.responsibility else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
