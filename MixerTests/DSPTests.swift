import XCTest
@testable import Mixer

final class DSPTests: XCTestCase {
    private var state: UnsafeMutablePointer<MixerChannelState>!

    override func setUp() {
        state = .allocate(capacity: 1)
    }

    override func tearDown() {
        state.deallocate()
    }

    /// Runs one interleaved block and returns the output.
    private func process(_ input: [Float], inChannels: UInt32, outChannels: UInt32) -> [Float] {
        let frames = UInt32(input.count) / inChannels
        var out = [Float](repeating: .nan, count: Int(frames * outChannels))
        input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                MixerProcessInterleaved(state, i.baseAddress!, inChannels, o.baseAddress!, outChannels, frames)
            }
        }
        return out
    }

    func testUnityGainCopiesStereo() {
        MixerChannelStateInit(state, 1)
        let input: [Float] = (0..<64).flatMap { _ -> [Float] in [0.1, -0.2] }
        XCTAssertEqual(process(input, inChannels: 2, outChannels: 2), input)
    }

    func testRampReachesTargetAtBufferEnd() {
        MixerChannelStateInit(state, 0)
        MixerChannelStateSetGain(state, 1)
        let out = process([Float](repeating: 1, count: 256), inChannels: 1, outChannels: 1)
        XCTAssertEqual(out[0], 0, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(out[255], 0.99)
        for i in 1..<out.count { XCTAssertGreaterThanOrEqual(out[i], out[i - 1]) }
    }

    func testRampIsContinuousAcrossBuffers() {
        MixerChannelStateInit(state, 0.2)
        MixerChannelStateSetGain(state, 0.8)
        let first = process([Float](repeating: 1, count: 128), inChannels: 1, outChannels: 1)
        MixerChannelStateSetGain(state, 0.4)
        let second = process([Float](repeating: 1, count: 128), inChannels: 1, outChannels: 1)
        let step = Float(0.6 / 128)
        // The second buffer starts where the first one ended (no jump back to an old gain).
        XCTAssertLessThanOrEqual(abs(second[0] - first[127]), step * 1.01)
    }

    func testMuteIsSilentAfterOneBuffer() {
        MixerChannelStateInit(state, 1)
        MixerChannelStateSetGain(state, 0)
        _ = process([Float](repeating: 0.5, count: 256), inChannels: 2, outChannels: 2)
        let second = process([Float](repeating: 0.5, count: 256), inChannels: 2, outChannels: 2)
        XCTAssertTrue(second.allSatisfy { $0 == 0 })
    }

    func testLimiterOnlyAboveUnity() {
        MixerChannelStateInit(state, 1)
        XCTAssertEqual(process([0.95, 0.95], inChannels: 2, outChannels: 2), [0.95, 0.95])
        MixerChannelStateInit(state, 2.25)
        let boosted = process([0.9, -0.9], inChannels: 2, outChannels: 2)
        XCTAssertLessThan(abs(boosted[0]), 1.0)
        XCTAssertLessThan(abs(boosted[1]), 1.0)
        XCTAssertLessThan(boosted[1], 0)
    }

    func testStereoToMonoDownmix() {
        MixerChannelStateInit(state, 1)
        let out = process([0.4, 0.2, 0.4, 0.2], inChannels: 2, outChannels: 1)
        XCTAssertEqual(out[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(out[1], 0.3, accuracy: 1e-6)
    }

    func testStereoToEightChannels() {
        MixerChannelStateInit(state, 1)
        let out = process([0.4, 0.2], inChannels: 2, outChannels: 8)
        XCTAssertEqual(out, [0.4, 0.2, 0, 0, 0, 0, 0, 0])
    }

    func testNaNGainTreatedAsZero() {
        MixerChannelStateInit(state, 1)
        MixerChannelStateSetGain(state, .nan)
        XCTAssertEqual(MixerChannelStateGetTargetGain(state), 0)
    }
}
