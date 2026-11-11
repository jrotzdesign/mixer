import XCTest
@testable import Mixer

final class VolumeTests: XCTestCase {
    func testGainTaper() {
        XCTAssertEqual(AppVolume(percent: 50).gain, 0.25, accuracy: 1e-6)
        XCTAssertEqual(AppVolume(percent: 100).gain, 1.0, accuracy: 1e-6)
        XCTAssertEqual(AppVolume(percent: 150).gain, 2.25, accuracy: 1e-6)
        XCTAssertEqual(AppVolume(percent: 80, muted: true).gain, 0)
    }

    func testNeedsChannel() {
        XCTAssertFalse(AppVolume(percent: 100, muted: false).needsChannel)
        XCTAssertTrue(AppVolume(percent: 99, muted: false).needsChannel)
        XCTAssertTrue(AppVolume(percent: 100, muted: true).needsChannel)
    }

    func testNudgeClamps() {
        let high = AppVolume(percent: 145).nudged(by: AppVolume.step)
        XCTAssertEqual(high.percent, 150)
        XCTAssertEqual(high.nudged(by: AppVolume.step).percent, AppVolume.maxPercent)
        XCTAssertEqual(AppVolume(percent: 3).nudged(by: -AppVolume.step).percent, 0)
    }

    func testNudgeKeepsMuteState() {
        XCTAssertTrue(AppVolume(percent: 50, muted: true).nudged(by: 5).muted)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.setVolume(AppVolume(percent: 40, muted: true), for: "com.spotify.client")
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.volume(for: "com.spotify.client"), AppVolume(percent: 40, muted: true))
    }

    func testUnknownKeyIsDefault() {
        XCTAssertEqual(SettingsStore(defaults: defaults).volume(for: "nope"), AppVolume())
    }

    func testDefaultValueNotPersisted() {
        let store = SettingsStore(defaults: defaults)
        store.setVolume(AppVolume(percent: 40), for: "a")
        store.setVolume(AppVolume(), for: "a")
        let stored = defaults.dictionary(forKey: SettingsStore.volumesKey) ?? [:]
        XCTAssertNil(stored["a"])
    }

    func testPinnedKeyRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.pinnedAppKey = "com.google.Chrome"
        XCTAssertEqual(SettingsStore(defaults: defaults).pinnedAppKey, "com.google.Chrome")
    }

    func testResetClearsVolumesKeepsPin() {
        let store = SettingsStore(defaults: defaults)
        store.setVolume(AppVolume(percent: 10), for: "a")
        store.pinnedAppKey = "b"
        store.resetAllVolumes()
        XCTAssertEqual(store.volume(for: "a"), AppVolume())
        XCTAssertEqual(store.pinnedAppKey, "b")
    }
}
