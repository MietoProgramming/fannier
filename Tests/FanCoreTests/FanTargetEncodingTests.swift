import XCTest
@testable import FanSMC

final class FanTargetEncodingTests: XCTestCase {
    func testFloatTargetUsesLittleEndianBitPattern() throws {
        XCTAssertEqual(
            try FanTargetEncoder.encode(type: "flt ", rpm: 2_651),
            [0x00, 0xB0, 0x25, 0x45]
        )
    }

    func testFPE2TargetUsesBigEndianFixedPoint() throws {
        XCTAssertEqual(
            try FanTargetEncoder.encode(type: "fpe2", rpm: 2_651),
            [0x29, 0x6C]
        )
    }

    func testFPE2RejectsValuesOutsideRepresentableRange() {
        XCTAssertThrowsError(try FanTargetEncoder.encode(type: "fpe2", rpm: 16_384))
    }
}
