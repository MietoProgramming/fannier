import XCTest
@testable import FanCore

final class ControlEngineTests: XCTestCase {
    private func makeCurve(_ points: (Double, Int)...) -> FanProfile {
        FanProfile(
            name: "test", sensor: .max,
            curve: points.map { FanProfile.CurvePoint(tempC: $0, rpm: $1) },
            hysteresisRPM: 0, emergencyTempC: 95
        )
    }

    func testBelowFirstAnchorUsesFirstRPM() {
        let profile = makeCurve((40, 2000), (80, 6000))
        XCTAssertEqual(ControlEngine.targetRPM(profile: profile, tempC: 20), 2000)
    }

    func testAboveLastAnchorUsesLastRPM() {
        let profile = makeCurve((40, 2000), (80, 6000))
        XCTAssertEqual(ControlEngine.targetRPM(profile: profile, tempC: 95), 6000)
    }

    func testMidpointIsInterpolated() {
        let profile = makeCurve((40, 2000), (80, 6000))
        XCTAssertEqual(ControlEngine.targetRPM(profile: profile, tempC: 60), 4000)
    }

    func testUnsortedCurveIsSorted() {
        let profile = FanProfile(
            name: "unsorted", sensor: .cpu,
            curve: [.init(tempC: 80, rpm: 6000), .init(tempC: 40, rpm: 2000)],
            hysteresisRPM: 0, emergencyTempC: 95
        )
        XCTAssertEqual(ControlEngine.targetRPM(profile: profile, tempC: 60), 4000)
    }

    func testOnePointCurveReturnsNil() {
        let profile = makeCurve((40, 2000))
        XCTAssertNil(ControlEngine.targetRPM(profile: profile, tempC: 50))
    }

    func testCommandClampsToFanLimits() {
        let profile = makeCurve((40, 1000), (80, 9000))
        let command = ControlEngine.command(
            profile: profile, cpuTemp: 80, gpuTemp: nil, fanMin: 2317, fanMax: 7826, lastTarget: nil
        )
        XCTAssertEqual(command?.rpm, 7826)
    }

    func testEmergencyOverridesAndGoesToMax() {
        var profile = makeCurve((40, 2400), (80, 5000))
        profile.emergencyTempC = 95
        let command = ControlEngine.command(
            profile: profile, cpuTemp: 96, gpuTemp: 40, fanMin: 2317, fanMax: 7826, lastTarget: 3000
        )
        XCTAssertEqual(command?.rpm, 7826)
        XCTAssertEqual(command?.emergency, true)
    }

    func testHysteresisSuppressesTinyChanges() {
        var profile = makeCurve((40, 2400), (80, 5000))
        profile.hysteresisRPM = 200
        // 65 rpm per °C: at 60 °C → 3700, |3700 − 3200| = 500 ≥ 200 → applied
        let first = ControlEngine.command(
            profile: profile, cpuTemp: 60, gpuTemp: nil, fanMin: 2317, fanMax: 7826, lastTarget: 3200
        )
        XCTAssertEqual(first?.rpm, 3700)

        // at 60.5 °C → ~3733, Δ33 < 200 → suppressed
        let second = ControlEngine.command(
            profile: profile, cpuTemp: 60.5, gpuTemp: nil, fanMin: 2317, fanMax: 7826, lastTarget: 3700
        )
        XCTAssertNil(second, "Δ33 rpm must be suppressed by hysteresis 200")
    }

    func testNoProfileReturnsNil() {
        XCTAssertNil(ControlEngine.command(
            profile: nil, cpuTemp: 60, gpuTemp: 60, fanMin: 2000, fanMax: 8000, lastTarget: nil
        ))
    }

    func testBuiltInProfilesHaveMonotonicCurves() {
        for profile in FanProfile.builtIns {
            XCTAssertGreaterThanOrEqual(profile.curve.count, 2, profile.name)
            let sorted = profile.curve.map(\.tempC)
            XCTAssertEqual(sorted, sorted.sorted(), "\(profile.name) curve not sorted by temp")
            for (a, b) in zip(profile.curve, profile.curve.dropFirst()) {
                XCTAssertLessThan(a.rpm, b.rpm, "\(profile.name) rpm must increase with temp")
            }
        }
    }
}
