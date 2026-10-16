import XCTest
@testable import FanCore

final class ProfileValidatorTests: XCTestCase {
    private func makeProfile(
        name: String = "Test",
        curve: [FanProfile.CurvePoint],
        hysteresis: Int = 75,
        emergency: Double = 95
    ) -> FanProfile {
        FanProfile(name: name, sensor: .max, curve: curve,
                   hysteresisRPM: hysteresis, emergencyTempC: emergency)
    }

    private func success(_ result: Result<FanProfile, ProfileValidationError>) -> FanProfile? {
        guard case .success(let clean) = result else {
            XCTFail("expected success, got \(result)")
            return nil
        }
        return clean
    }

    private func failure(_ result: Result<FanProfile, ProfileValidationError>) -> String? {
        guard case .failure(let reason) = result else {
            XCTFail("expected failure, got \(result)")
            return nil
        }
        return reason.message
    }

    func testSortsCurveByTemperature() {
        let clean = success(ProfileValidator.sanitize(makeProfile(curve: [
            .init(tempC: 80, rpm: 5_000),
            .init(tempC: 40, rpm: 2_500),
            .init(tempC: 60, rpm: 3_500),
        ])))
        XCTAssertEqual(clean?.curve.map(\.tempC), [40, 60, 80])
        XCTAssertEqual(clean?.curve.map(\.rpm), [2_500, 3_500, 5_000])
    }

    func testMergesEqualTemperaturesKeepingLastDefinition() {
        let clean = success(ProfileValidator.sanitize(makeProfile(curve: [
            .init(tempC: 50, rpm: 3_000),
            .init(tempC: 50, rpm: 3_300),
            .init(tempC: 70, rpm: 4_000),
        ])))
        XCTAssertEqual(clean?.curve.count, 2)
        XCTAssertEqual(clean?.curve.first?.rpm, 3_300)
    }

    func testClampsRPMAndTemperatureIntoHardBounds() {
        let clean = success(ProfileValidator.sanitize(makeProfile(curve: [
            .init(tempC: -10, rpm: -500),
            .init(tempC: 200, rpm: 90_000),
        ])))
        XCTAssertEqual(clean?.curve.first?.tempC, 0)
        XCTAssertEqual(clean?.curve.first?.rpm, 0)
        XCTAssertEqual(clean?.curve.last?.tempC, 120)
        XCTAssertEqual(clean?.curve.last?.rpm, ProfileValidator.rpmHardMax)
    }

    func testRejectsCurveWithFewerThanTwoDistinctSteps() {
        XCTAssertNotNil(failure(ProfileValidator.sanitize(makeProfile(curve: [
            .init(tempC: 50, rpm: 3_000),
        ]))))
        XCTAssertNotNil(failure(ProfileValidator.sanitize(makeProfile(curve: [
            .init(tempC: 50, rpm: 3_000),
            .init(tempC: 50.0001, rpm: 3_100),
        ]))))
    }

    func testRejectsEmptyOrOverlongName() {
        XCTAssertEqual(
            failure(ProfileValidator.sanitize(makeProfile(
                name: "   ", curve: [.init(tempC: 40, rpm: 2_400), .init(tempC: 80, rpm: 5_000)]
            ))),
            "profile name is empty"
        )
        let longName = String(repeating: "a", count: ProfileValidator.maxNameLength + 1)
        XCTAssertNotNil(failure(ProfileValidator.sanitize(makeProfile(
            name: longName, curve: [.init(tempC: 40, rpm: 2_400), .init(tempC: 80, rpm: 5_000)]
        ))))
    }

    func testTrimsName() {
        let clean = success(ProfileValidator.sanitize(makeProfile(
            name: "  Quiet 2  ", curve: [.init(tempC: 40, rpm: 2_400), .init(tempC: 80, rpm: 5_000)]
        )))
        XCTAssertEqual(clean?.name, "Quiet 2")
    }

    func testClampsHysteresisAndEmergency() {
        let clean = success(ProfileValidator.sanitize(makeProfile(
            curve: [.init(tempC: 40, rpm: 2_400), .init(tempC: 80, rpm: 5_000)],
            hysteresis: 9_999, emergency: 250
        )))
        XCTAssertEqual(clean?.hysteresisRPM, ProfileValidator.hysteresisRange.upperBound)
        XCTAssertEqual(clean?.emergencyTempC, ProfileValidator.emergencyRange.upperBound)

        let low = success(ProfileValidator.sanitize(makeProfile(
            curve: [.init(tempC: 40, rpm: 2_400), .init(tempC: 80, rpm: 5_000)],
            hysteresis: -5, emergency: 10
        )))
        XCTAssertEqual(low?.hysteresisRPM, ProfileValidator.hysteresisRange.lowerBound)
        XCTAssertEqual(low?.emergencyTempC, ProfileValidator.emergencyRange.lowerBound)
    }

    func testBuiltInsSurviveSanitizeUnchangedExceptSorting() {
        for builtIn in FanProfile.builtIns {
            let clean = success(ProfileValidator.sanitize(builtIn))
            XCTAssertEqual(clean, builtIn, "built-in \(builtIn.name) should be valid as-is")
        }
    }
}
