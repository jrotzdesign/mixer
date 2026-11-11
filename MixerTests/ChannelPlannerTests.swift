import XCTest
@testable import Mixer

final class ChannelPlannerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func group(_ key: String, _ objects: [AudioObjectID] = [10], playing: Bool = true, name: String? = nil) -> AppGroup {
        AppGroup(identity: AppIdentity(key: key, name: name ?? key, bundleURL: nil, ownerPID: 1),
                 processObjects: objects, isPlaying: playing)
    }

    private func volumes(_ map: [String: AppVolume]) -> (String) -> AppVolume {
        { map[$0] ?? AppVolume() }
    }

    func testSavedVolumeCreatesChannelBeforePlaying() {
        var p = ChannelPlanner()
        let plan = p.plan(groups: [group("game", playing: false)], volume: volumes(["game": AppVolume(percent: 60)]),
                          existing: [:], permissionGranted: true, now: t0)
        XCTAssertEqual(plan.create, ["game"])
    }

    func testDefaultVolumeNoChannel() {
        var p = ChannelPlanner()
        let plan = p.plan(groups: [group("a")], volume: volumes([:]), existing: [:], permissionGranted: true, now: t0)
        XCTAssertEqual(plan, ChannelPlan(create: [], update: [], destroy: []))
    }

    func testPausedAppKeepsChannel() {
        var p = ChannelPlanner()
        let plan = p.plan(groups: [group("a", playing: false)], volume: volumes(["a": AppVolume(percent: 60)]),
                          existing: ["a": [10]], permissionGranted: true, now: t0)
        XCTAssertEqual(plan.destroy, [])
    }

    func testQuitDestroysImmediately() {
        var p = ChannelPlanner()
        let plan = p.plan(groups: [], volume: volumes(["a": AppVolume(percent: 60)]),
                          existing: ["a": [10]], permissionGranted: true, now: t0)
        XCTAssertEqual(plan.destroy, ["a"])
    }

    func testReleaseAfterTenSecondsAtDefault() {
        var p = ChannelPlanner()
        let g = [group("a")]
        let existing: [String: [AudioObjectID]] = ["a": [10]]
        XCTAssertEqual(p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true, now: t0).destroy, [])
        XCTAssertEqual(p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true,
                              now: t0 + 9).destroy, [])
        XCTAssertEqual(p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true,
                              now: t0 + 10).destroy, ["a"])
    }

    func testMovingOffDefaultCancelsRelease() {
        var p = ChannelPlanner()
        let g = [group("a")]
        let existing: [String: [AudioObjectID]] = ["a": [10]]
        _ = p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true, now: t0)
        _ = p.plan(groups: g, volume: volumes(["a": AppVolume(percent: 60)]), existing: existing,
                   permissionGranted: true, now: t0 + 5)
        // Back at 100 % at t0+6: the 10 s clock restarts, so nothing is released at t0+12.
        _ = p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true, now: t0 + 6)
        XCTAssertEqual(p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true,
                              now: t0 + 12).destroy, [])
        XCTAssertEqual(p.plan(groups: g, volume: volumes([:]), existing: existing, permissionGranted: true,
                              now: t0 + 16).destroy, ["a"])
    }

    func testMuteCreatesChannel() {
        var p = ChannelPlanner()
        let plan = p.plan(groups: [group("a")], volume: volumes(["a": AppVolume(percent: 100, muted: true)]),
                          existing: [:], permissionGranted: true, now: t0)
        XCTAssertEqual(plan.create, ["a"])
    }

    func testHelperChangeIsUpdate() {
        var p = ChannelPlanner()
        let plan = p.plan(groups: [group("a", [10, 11])], volume: volumes(["a": AppVolume(percent: 60)]),
                          existing: ["a": [10]], permissionGranted: true, now: t0)
        XCTAssertEqual(plan, ChannelPlan(create: [], update: ["a"], destroy: []))
    }

    func testNoChannelsWithoutPermission() {
        var p = ChannelPlanner()
        let vols = volumes(["a": AppVolume(percent: 60), "b": AppVolume(percent: 20)])
        let plan = p.plan(groups: [group("a"), group("b")], volume: vols,
                          existing: ["b": [10]], permissionGranted: false, now: t0)
        XCTAssertEqual(plan, ChannelPlan(create: [], update: [], destroy: ["b"]))
    }
}

final class RowVisibilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func group(_ key: String, playing: Bool, name: String) -> AppGroup {
        AppGroup(identity: AppIdentity(key: key, name: name, bundleURL: nil, ownerPID: 1),
                 processObjects: [1], isPlaying: playing)
    }

    func testRowLingersFiveSeconds() {
        var v = RowVisibility()
        XCTAssertEqual(v.visibleKeys(groups: [group("a", playing: true, name: "A")], now: t0), ["a"])
        let stopped = [group("a", playing: false, name: "A")]
        XCTAssertEqual(v.visibleKeys(groups: stopped, now: t0 + 4), ["a"])
        XCTAssertEqual(v.visibleKeys(groups: stopped, now: t0 + 5), [])
    }

    func testRowRemovedImmediatelyOnQuit() {
        var v = RowVisibility()
        _ = v.visibleKeys(groups: [group("a", playing: true, name: "A")], now: t0)
        XCTAssertEqual(v.visibleKeys(groups: [], now: t0 + 1), [])
    }

    func testNeverPlayingAppHidden() {
        var v = RowVisibility()
        XCTAssertEqual(v.visibleKeys(groups: [group("finder", playing: false, name: "Finder")], now: t0), [])
    }

    func testSortedByName() {
        var v = RowVisibility()
        let groups = [group("z", playing: true, name: "Alpha"), group("a", playing: true, name: "beta")]
        XCTAssertEqual(v.visibleKeys(groups: groups, now: t0), ["z", "a"])
    }
}
