import XCTest
@testable import FanCore

final class WriteGateTests: XCTestCase {
    private let now = Date()

    private func gate(
        rpm: Int = 3_000,
        lastTarget: Int?,
        observedTarget: Int? = 3_000,
        hysteresis: Int = 100,
        emergency: Bool = false,
        automatic: Bool = false,
        lastWriteAgo: TimeInterval?,
        heartbeat: TimeInterval = 2.0,
        force: Bool = false
    ) -> Bool {
        WriteGate.shouldWrite(
            rpm: rpm,
            lastTarget: lastTarget,
            observedTarget: observedTarget,
            hysteresisRPM: hysteresis,
            emergency: emergency,
            fanIsAutomatic: automatic,
            lastWriteAt: lastWriteAgo.map { now.addingTimeInterval(-$0) },
            now: now,
            heartbeat: heartbeat,
            force: force
        )
    }

    func testWritesWhenNeverApplied() {
        XCTAssertTrue(gate(lastTarget: nil, lastWriteAgo: nil))
    }

    func testSkipsSmallChangeBeforeHeartbeat() {
        XCTAssertFalse(gate(rpm: 3_050, lastTarget: 3_000, lastWriteAgo: 1.0))
    }

    func testWritesOnSignificantChange() {
        XCTAssertTrue(gate(rpm: 3_200, lastTarget: 3_000, lastWriteAgo: 1.0))
    }

    func testWritesWhenHeartbeatElapsedEvenIfUnchanged() {
        XCTAssertTrue(gate(rpm: 3_000, lastTarget: 3_000, lastWriteAgo: 3.0))
    }

    func testWritesImmediatelyWhenFanFlippedBackToAutomatic() {
        // Even though the target is unchanged and the write was recent.
        XCTAssertTrue(gate(rpm: 3_000, lastTarget: 3_000, automatic: true, lastWriteAgo: 0.2))
    }

    func testWritesAgainWhenSMCZeroesTargetButKeepsManualMode() {
        XCTAssertTrue(gate(rpm: 3_000, lastTarget: 3_000, observedTarget: 0, lastWriteAgo: 0.2))
    }

    func testWritesWhenReadbackDriftsBeyondToleranceEvenInsideHysteresis() {
        XCTAssertTrue(gate(rpm: 3_051, lastTarget: 3_000, observedTarget: 3_000,
                           hysteresis: 100, lastWriteAgo: 0.2))
    }

    func testWritesWhenTargetReadbackIsUnavailable() {
        XCTAssertTrue(gate(rpm: 3_000, lastTarget: 3_000, observedTarget: nil, lastWriteAgo: 0.2))
    }

    func testEmergencyBypassesHysteresis() {
        XCTAssertTrue(gate(rpm: 3_050, lastTarget: 3_000, hysteresis: 100,
                           emergency: true, lastWriteAgo: 1.0))
    }

    func testForceAlwaysWrites() {
        XCTAssertTrue(gate(rpm: 3_000, lastTarget: 3_000, lastWriteAgo: 0.1, force: true))
    }

    func testHeartbeatDisabledStillWritesOnAutomatic() {
        XCTAssertTrue(gate(rpm: 3_000, lastTarget: 3_000, automatic: true,
                           lastWriteAgo: 100, heartbeat: 1_000))
    }
}
