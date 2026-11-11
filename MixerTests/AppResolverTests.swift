import XCTest
@testable import Mixer

/// A fake process table: pid → app info, parent, responsible pid, executable path.
private struct FakeProcessSource: ProcessInfoSource {
    var apps: [pid_t: RunningAppInfo] = [:]
    var parents: [pid_t: pid_t] = [:]
    var responsible: [pid_t: pid_t] = [:]
    var paths: [pid_t: String] = [:]

    func runningApp(pid: pid_t) -> RunningAppInfo? { apps[pid] }
    func responsiblePID(for pid: pid_t) -> pid_t? { responsible[pid] }
    func parentPID(of pid: pid_t) -> pid_t? { parents[pid] }
    func executablePath(pid: pid_t) -> String? { paths[pid] }

    mutating func addApp(_ pid: pid_t, _ bundleID: String?, _ name: String, bundle: String?, regular: Bool, parent: pid_t = 1) {
        apps[pid] = RunningAppInfo(pid: pid, bundleID: bundleID, name: name,
                                   bundleURL: bundle.map { URL(fileURLWithPath: $0) }, isRegular: regular)
        parents[pid] = parent
    }
}

final class AppResolverTests: XCTestCase {
    private let selfPID: pid_t = 999

    private func resolver(_ source: FakeProcessSource) -> AppResolver {
        AppResolver(source: source, selfPID: selfPID)
    }

    func testRegularAppIsItsOwnOwner() {
        var s = FakeProcessSource()
        s.addApp(100, "com.spotify.client", "Spotify", bundle: "/Applications/Spotify.app", regular: true)
        let id = resolver(s).resolve(pid: 100)
        XCTAssertEqual(id?.key, "com.spotify.client")
        XCTAssertEqual(id?.name, "Spotify")
        XCTAssertEqual(id?.ownerPID, 100)
    }

    func testTerminalLaunchedGameNotFoldedIntoTerminal() {
        var s = FakeProcessSource()
        s.addApp(50, "com.apple.Terminal", "Terminal", bundle: "/System/Applications/Utilities/Terminal.app", regular: true)
        s.addApp(200, "org.example.game", "Game", bundle: "/Games/Game.app", regular: true, parent: 50)
        s.responsible[200] = 50
        XCTAssertEqual(resolver(s).resolve(pid: 200)?.key, "org.example.game")
    }

    func testOOTDmhostIsOneRowWithLauncher() {
        var s = FakeProcessSource()
        let ootID = "org.nxnative.0400486024dec000"
        let bundle = "/Users/x/Downloads/OOT-main/OOT.app"
        s.addApp(300, ootID, "The Legend of Zelda: Ocarina of Time", bundle: bundle, regular: true)
        s.addApp(301, ootID, "The Legend of Zelda: Ocarina of Time", bundle: bundle, regular: true, parent: 300)
        let r = resolver(s)
        XCTAssertEqual(r.resolve(pid: 301)?.key, ootID)
        XCTAssertEqual(r.resolve(pid: 300)?.key, ootID)
        XCTAssertEqual(r.resolve(pid: 301)?.name, "The Legend of Zelda: Ocarina of Time")
    }

    func testChromeHelperWalksToParent() {
        var s = FakeProcessSource()
        s.addApp(400, "com.google.Chrome", "Google Chrome", bundle: "/Applications/Google Chrome.app", regular: true)
        s.addApp(401, "com.google.Chrome.helper", "Google Chrome Helper",
                 bundle: "/Applications/Google Chrome.app/Contents/Frameworks/x/Helpers/Google Chrome Helper.app",
                 regular: false, parent: 400)
        let id = resolver(s).resolve(pid: 401)
        XCTAssertEqual(id?.key, "com.google.Chrome")
        XCTAssertEqual(id?.ownerPID, 400)
    }

    func testWebKitXPCUsesResponsiblePID() {
        var s = FakeProcessSource()
        s.addApp(500, "com.apple.Safari", "Safari", bundle: "/Applications/Safari.app", regular: true)
        s.addApp(501, "com.apple.WebKit.WebContent", "Safari Web Content",
                 bundle: "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent.xpc",
                 regular: false, parent: 1)
        s.responsible[501] = 500
        XCTAssertEqual(resolver(s).resolve(pid: 501)?.key, "com.apple.Safari")
    }

    func testOpenEmuHelperFoldsIntoOpenEmu() {
        var s = FakeProcessSource()
        s.addApp(600, "org.openemu.OpenEmu", "OpenEmu", bundle: "/Applications/OpenEmu.app", regular: true)
        s.apps[601] = nil
        s.parents[601] = 600
        s.paths[601] = "/Applications/OpenEmu.app/Contents/MacOS/OpenEmuHelperApp"
        XCTAssertEqual(resolver(s).resolve(pid: 601)?.key, "org.openemu.OpenEmu")
    }

    func testCLIProcessUsesPathKey() {
        var s = FakeProcessSource()
        s.parents[700] = 650  // zsh, not an app
        s.parents[650] = 1
        s.paths[700] = "/usr/bin/afplay"
        let id = resolver(s).resolve(pid: 700)
        XCTAssertEqual(id?.key, "path:/usr/bin/afplay")
        XCTAssertEqual(id?.name, "afplay")
        XCTAssertNil(id?.bundleURL)
    }

    func testCLIFromTerminalKeepsOwnRow() {
        var s = FakeProcessSource()
        s.addApp(50, "com.apple.Terminal", "Terminal", bundle: "/System/Applications/Utilities/Terminal.app", regular: true)
        s.parents[51] = 50   // zsh
        s.parents[700] = 51  // afplay
        s.responsible[700] = 50
        s.paths[700] = "/usr/bin/afplay"
        XCTAssertEqual(resolver(s).resolve(pid: 700)?.key, "path:/usr/bin/afplay")
    }

    func testSelfIsExcluded() {
        var s = FakeProcessSource()
        s.addApp(selfPID, "com.jrortizdesign.mixer", "Mixer", bundle: "/Applications/Mixer.app", regular: false)
        XCTAssertNil(resolver(s).resolve(pid: selfPID))
    }

    func testManyHelpersOneGroup() {
        var s = FakeProcessSource()
        s.addApp(800, "com.google.Chrome", "Google Chrome", bundle: "/Applications/Google Chrome.app", regular: true)
        for pid in pid_t(801)...810 {
            s.addApp(pid, "com.google.Chrome.helper", "Helper",
                     bundle: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app", regular: false, parent: 800)
        }
        let keys = Set((pid_t(801)...810).compactMap { resolver(s).resolve(pid: $0)?.key })
        XCTAssertEqual(keys, ["com.google.Chrome"])
    }

    func testParentCycleTerminates() {
        var s = FakeProcessSource()
        s.parents[900] = 901
        s.parents[901] = 900
        s.paths[900] = "/usr/local/bin/loop"
        XCTAssertEqual(resolver(s).resolve(pid: 900)?.key, "path:/usr/local/bin/loop")
    }
}
