import XCTest
import FanSMC
@testable import FanCore

final class ControllerTests: XCTestCase {
    func testProfileActivationWritesAndConfirmsEveryFan() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        XCTAssertNil(controller.useProfile("Performance"))
        for id in 0 ..< 2 {
            XCTAssertEqual(hardware.fan(id)?.targetRPM, 4_400)
            XCTAssertEqual(hardware.fan(id)?.automatic, false)
            XCTAssertEqual(controller.currentStatus().fans[id].desiredRPM, 4_400)
            XCTAssertNotNil(controller.currentStatus().fans[id].lastConfirmedAt)
        }
    }

    func testTargetDriftToZeroIsReassertedWithoutModeChange() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        XCTAssertNil(controller.useProfile("Performance"))
        let modeWritesBefore = hardware.modeWriteCount
        hardware.setTargetForTesting(0, fan: 0)

        XCTAssertNil(controller.applyOnce())
        XCTAssertEqual(hardware.fan(0)?.targetRPM, 4_400)
        XCTAssertEqual(hardware.modeWriteCount, modeWritesBefore)
    }

    func testDelayedTargetReadbackDoesNotRewriteManualMode() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        hardware.staleTargetReadsAfterWrite = 6

        XCTAssertNil(controller.useProfile("Performance"))

        XCTAssertEqual(hardware.modeWriteCount, 2, "write manual mode only once per fan while the target settles")
        XCTAssertEqual(hardware.targetWriteCount, 2)
        for id in 0 ..< 2 {
            XCTAssertEqual(hardware.fan(id)?.targetRPM, 4_400)
            XCTAssertNotNil(controller.currentStatus().fans[id].lastConfirmedAt)
        }
    }

    func testSilentZeroTargetReadbackFailsActivationAndIsReported() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        hardware.discardTargetWrites = true

        let error = controller.useProfile("Performance")
        XCTAssertTrue(error?.contains("fan0") == true)
        XCTAssertTrue(error?.contains("requested 4400 rpm") == true)
        XCTAssertEqual(controller.activeProfileName(), "Performance", "saved selection remains active for retry")
        XCTAssertEqual(controller.currentStatus().fans[0].targetRPM, 0)
        XCTAssertNotNil(controller.currentStatus().fans[0].lastError)
    }

    func testEditingActiveProfileSurfacesApplyFailureAndKeepsSavedProfile() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        hardware.discardTargetWrites = true
        var profile = try XCTUnwrap(controller.profileDetails().first { $0.name == "Performance" })
        profile.hysteresisRPM += 1

        let result = controller.upsertProfile(profile)
        guard case .success(let outcome) = result else {
            return XCTFail("profile should be saved even when hardware application fails")
        }
        XCTAssertEqual(outcome.profile.hysteresisRPM, profile.hysteresisRPM)
        XCTAssertTrue(outcome.activationError?.contains("fan0") == true)
        XCTAssertEqual(store.load().profiles.first { $0.name == "Performance" }?.hysteresisRPM, profile.hysteresisRPM)
    }

    func testFailureOnOneFanDoesNotHideOtherFanOrReportSuccess() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        hardware.failingFanIDs = [1]

        let error = controller.useProfile("Performance")
        XCTAssertTrue(error?.contains("fan1") == true)
        XCTAssertEqual(hardware.fan(0)?.targetRPM, 4_400)
        XCTAssertEqual(controller.currentStatus().fans[1].targetRPM, 0)
    }

    func testAutomaticModePersistsAcrossDaemonRestartDespiteOldStateFile() throws {
        let (_, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        store.saveLastActive("Performance")
        let controller = Controller(smc: hardware, store: store)

        XCTAssertNil(controller.resumeAutomatic())
        let afterRestart = Controller(smc: hardware, store: ProfileStore(directory: store.directory))
        XCTAssertNil(afterRestart.activeProfileName())
        XCTAssertEqual(afterRestart.file.automaticMode, true)
    }

    func testDaemonShutdownRestoresFansWithoutForgettingSelectedProfile() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        XCTAssertNil(controller.useProfile("Performance"))

        controller.shutdownNow()
        let afterRestart = Controller(smc: hardware, store: ProfileStore(directory: store.directory))
        XCTAssertEqual(afterRestart.activeProfileName(), "Performance")
        XCTAssertFalse(afterRestart.file.automaticMode)
        XCTAssertTrue(hardware.allFans().allSatisfy(\.automatic))
    }

    func testTemporaryManualOverrideTakesPrecedenceOverPersistedAutomaticMode() throws {
        let (controller, hardware, store) = makeController()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        XCTAssertNil(controller.resumeAutomatic())

        XCTAssertNil(controller.setManual(fan: 0, rpm: 2_500))
        XCTAssertNil(controller.applyOnce())
        XCTAssertEqual(hardware.fan(0)?.targetRPM, 2_500)
        XCTAssertEqual(hardware.fan(0)?.automatic, false)
    }

    private func makeController() -> (Controller, MockFanHardware, ProfileStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fannier-controller-tests-\(UUID().uuidString)", isDirectory: true)
        let store = ProfileStore(directory: directory)
        let profiles = ProfileStore.ProfilesFile(active: "Performance", profiles: FanProfile.builtIns)
        try! store.save(profiles)
        let hardware = MockFanHardware()
        return (Controller(smc: hardware, store: store), hardware, store)
    }
}

private final class MockFanHardware: FanControlHardware {
    private(set) var fans: [Int: Fan] = [:]
    private(set) var modeWriteCount = 0
    private(set) var targetWriteCount = 0
    var failingFanIDs: Set<Int> = []
    var discardTargetWrites = false
    var staleTargetReadsAfterWrite = 0
    private var pendingTargets: [Int: (rpm: Int, staleReadsRemaining: Int)] = [:]

    init() {
        for id in 0 ..< 2 {
            fans[id] = Fan(
                id: id, name: "Fan \(id)", minRPM: 1_000, maxRPM: 8_000,
                actualRPM: 1_000, targetRPM: 0, automatic: true
            )
        }
    }

    func fanCount() -> Int { fans.count }
    func fan(_ id: Int) -> Fan? {
        if let pending = pendingTargets[id] {
            if pending.staleReadsRemaining == 0 {
                setTargetForTesting(pending.rpm, fan: id)
                pendingTargets.removeValue(forKey: id)
            } else {
                pendingTargets[id] = (pending.rpm, pending.staleReadsRemaining - 1)
            }
        }
        return fans[id]
    }
    func allFans() -> [Fan] { fans.values.sorted { $0.id < $1.id } }
    func maxTemperature(group: SensorGroup) -> Double? { group == .cpu ? 50 : 40 }
    func sensorReadings(group: SensorGroup) -> [(key: String, tempC: Double)] {
        [(group == .cpu ? "Tp00" : "Tg00", group == .cpu ? 50 : 40)]
    }

    func forceFanMode(_ id: Int) throws {
        guard let fan = fans[id] else { throw MockError.missingFan }
        modeWriteCount += 1
        fans[id] = Fan(id: id, name: fan.name, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                       actualRPM: fan.actualRPM, targetRPM: fan.targetRPM, automatic: false)
    }

    func restoreAutomaticMode(_ id: Int) throws {
        guard let fan = fans[id] else { throw MockError.missingFan }
        fans[id] = Fan(id: id, name: fan.name, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                       actualRPM: fan.actualRPM, targetRPM: fan.targetRPM, automatic: true)
    }

    func setFanTargetRPM(_ id: Int, rpm: Int) throws {
        guard !failingFanIDs.contains(id), fans[id] != nil else { throw MockError.writeFailed }
        targetWriteCount += 1
        guard !discardTargetWrites else { return }
        if staleTargetReadsAfterWrite > 0 {
            pendingTargets[id] = (rpm, staleTargetReadsAfterWrite)
        } else {
            setTargetForTesting(rpm, fan: id)
        }
    }

    func setTargetForTesting(_ rpm: Int, fan id: Int) {
        guard let fan = fans[id] else { return }
        fans[id] = Fan(id: id, name: fan.name, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                       actualRPM: fan.actualRPM, targetRPM: rpm, automatic: fan.automatic)
    }

    private enum MockError: Error { case missingFan, writeFailed }
}
