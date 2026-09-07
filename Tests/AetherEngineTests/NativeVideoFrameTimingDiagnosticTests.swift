import CoreMedia
import XCTest
@testable import AetherEngine

final class NativeVideoFrameTimingDiagnosticTests: XCTestCase {
    func testExistingInitializerHasUnknownDecodeMetadata() {
        let frame = NativeVideoFrameTime(source: .zero, item: .zero,
                                        segmentIndex: 12, isKeyframe: true, epoch: 1)
        XCTAssertNil(frame.sourceDecode)
        XCTAssertNil(frame.itemDecode)
        XCTAssertNil(frame.sampleDuration)
        XCTAssertNil(frame.h264NALTypeMask)
        XCTAssertNil(frame.muxWriteResult)
    }

    func testKeepsDecodeAxesAndDurationSeparateFromPresentation() {
        let source = CMTime(value: 2002, timescale: 30000)
        let dts = CMTime(value: 0, timescale: 30000)
        let duration = CMTime(value: 3003, timescale: 90000)
        let frame = NativeVideoFrameTime(source: source, item: source,
            segmentIndex: 177, isKeyframe: true, epoch: 2,
            sourceDecode: dts, itemDecode: dts, sampleDuration: duration,
            h264NALTypeMask: 1 << 1, muxWriteResult: -22)
        XCTAssertEqual(frame.sourceDecode, dts)
        XCTAssertEqual(frame.sampleDuration, duration)
        XCTAssertEqual(frame.h264NALTypeMask! & (1 << 5), 0)
        // A keyframe flag with a non-IDR slice must remain observable, not relabeled.
        XCTAssertTrue(frame.isKeyframe)
        XCTAssertEqual(frame.muxWriteResult, -22)
    }
}
