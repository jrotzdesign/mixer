import XCTest
@testable import Mixer

@MainActor
final class AudioEngineTests: XCTestCase {
    private var suite: String!
    private var store: SettingsStore!
    private var engine: AudioEngine!
    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    override func setUp() {
        suite = UUID().uuidString
        store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        engine = AudioEngine(settings: store, resolver: AppResolver(source: SystemProcessInfo()), live: false)
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func group(_ key: String, _ name: String, playing: Bool) -> AppGroup {
        AppGroup(identity: AppIdentity(key: key, name: name, bundleURL: nil, ownerPID: 42),
                 processObjects: [7], isPlaying: playing)
    }

    func testRowsFollowVisibilityAndSettings() {
        store.setVolume(AppVolume(percent: 40), for: "b")
        store.pinnedAppKey = "a"
        engine.ingest(groups: [group("a", "Zed", playing: true), group("b", "Alpha", playing: true),
                               group("c", "Finder", playing: false)], now: t0)
        XCTAssertEqual(engine.rows.map(\.id), ["b", "a"])
        XCTAssertEqual(engine.rows[0].volume.percent, 40)
        XCTAssertTrue(engine.rows[1].isPinned)
        XCTAssertFalse(engine.rows[0].isPinned)
        XCTAssertEqual(engine.rows[1].pid, 42)
    }

    func testSetPercentUpdatesRowAndStore() {
        engine.ingest(groups: [group("a", "A", playing: true)], now: t0)
        engine.setPercent(70, for: "a")
        XCTAssertEqual(engine.rows.first?.volume.percent, 70)
        XCTAssertEqual(store.volume(for: "a").percent, 70)
    }

    func testNudgeAndToggleMuteWorkForAppsWithoutRows() {
        let v = engine.nudge("not-playing", by: -5)
        XCTAssertEqual(v.percent, 95)
        XCTAssertTrue(engine.toggleMute(for: "not-playing").muted)
        XCTAssertEqual(store.volume(for: "not-playing"), AppVolume(percent: 95, muted: true))
    }

    func testSetPercentClamps() {
        engine.setPercent(400, for: "a")
        XCTAssertEqual(store.volume(for: "a").percent, AppVolume.maxPercent)
    }
}
