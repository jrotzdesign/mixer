import Foundation

/// What we know about a running app from AppKit.
struct RunningAppInfo: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let bundleURL: URL?
    /// True for apps with a Dock presence (`.regular` activation policy).
    let isRegular: Bool
}

/// The process facts the resolver needs; faked in tests.
protocol ProcessInfoSource {
    func runningApp(pid: pid_t) -> RunningAppInfo?
    func responsiblePID(for pid: pid_t) -> pid_t?
    func parentPID(of pid: pid_t) -> pid_t?
    func executablePath(pid: pid_t) -> String?
}

/// The app a process belongs to: one row in the mixer, one saved volume.
struct AppIdentity: Hashable, Sendable {
    /// Bundle ID, or `path:<executable>` when there is none.
    let key: String
    let name: String
    let bundleURL: URL?
    let ownerPID: pid_t
}

/// Maps an audio process to its owning app, folding helper processes
/// (browser renderers, Electron helpers, XPC services, emulator cores) into
/// the app that launched them. Rules, in order (PLAN §5.2):
/// 1. A regular app is its own owner (so a game launched from Terminal stays a game).
/// 2. A launchd-parented process (XPC service) uses its responsible app.
/// 3. Otherwise, the nearest ancestor app whose bundle contains this process.
/// 4. Otherwise, the process itself, keyed by its executable path.
struct AppResolver {
    private let source: ProcessInfoSource
    private let selfPID: pid_t
    private static let maxDepth = 16

    init(source: ProcessInfoSource, selfPID: pid_t = getpid()) {
        self.source = source
        self.selfPID = selfPID
    }

    func resolve(pid: pid_t) -> AppIdentity? {
        guard pid != selfPID else { return nil }
        let owner = ownerApp(of: pid)
        if let owner {
            return owner.pid == selfPID ? nil : identity(for: owner)
        }
        let path = source.executablePath(pid: pid)
        return AppIdentity(key: path.map { "path:\($0)" } ?? "pid:\(pid)",
                           name: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Process \(pid)",
                           bundleURL: nil,
                           ownerPID: pid)
    }

    private func ownerApp(of pid: pid_t) -> RunningAppInfo? {
        let me = source.runningApp(pid: pid)
        if let me, me.isRegular { return me }

        let parent = source.parentPID(of: pid) ?? 1
        if parent <= 1, let r = source.responsiblePID(for: pid), r != pid,
           let app = source.runningApp(pid: r), app.bundleURL?.pathExtension == "app" {
            return app
        }

        if let location = source.executablePath(pid: pid) ?? me?.bundleURL?.path {
            var current = parent
            var visited: Set<pid_t> = [pid]
            while current > 1, visited.count <= Self.maxDepth, visited.insert(current).inserted {
                if let app = source.runningApp(pid: current), let bundle = app.bundleURL,
                   bundle.pathExtension == "app", location.hasPrefix(bundle.path + "/") {
                    return app
                }
                current = source.parentPID(of: current) ?? 1
            }
        }

        // A bundled background process with no owning app (an agent with its own bundle).
        return me
    }

    private func identity(for app: RunningAppInfo) -> AppIdentity {
        let key = app.bundleID
            ?? source.executablePath(pid: app.pid).map { "path:\($0)" }
            ?? app.bundleURL.map { "path:\($0.path)" }
            ?? "pid:\(app.pid)"
        return AppIdentity(key: key, name: app.name, bundleURL: app.bundleURL, ownerPID: app.pid)
    }
}
