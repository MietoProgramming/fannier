import Foundation
import FanSMC

/// Owns the SMC connection, the profile loop, and manual overrides.
/// Runs inside fanierd (root). The daemon main file owns the timer; this class
/// exposes evaluate()/apply()/handle() so it stays testable.
public final class Controller {
    private let smc: SMCConnection
    private let store: ProfileStore

    public private(set) var file: ProfileStore.ProfilesFile
    private var lastTargets: [Int: Int] = [:]
    private var manualFanRPM: [Int: Int] = [:]

    public init(smc: SMCConnection, store: ProfileStore) {
        self.smc = smc
        self.store = store
        self.file = store.load()
    }

    // MARK: - state

    public func currentStatus() -> MachineStatus {
        let fans = smc.allFans().map {
            MachineStatus.FanState(
                id: $0.id, name: $0.name, actualRPM: $0.actualRPM,
                minRPM: $0.minRPM, maxRPM: $0.maxRPM, automatic: $0.automatic
            )
        }
        let temps: [MachineStatus.TempState] = SensorGroup.allCases.compactMap { group in
            smc.maxTemperature(group: group).map {
                MachineStatus.TempState(group: group.rawValue, maxC: $0)
            }
        }
        return MachineStatus(
            fans: fans,
            temps: temps,
            activeProfile: activeProfileName(),
            manualOverride: !manualFanRPM.isEmpty
        )
    }

    public func profileNames() -> [String] {
        file.profiles.map { $0.name }
    }

    public func activeProfileName() -> String? {
        if !manualFanRPM.isEmpty { return nil }
        return file.active ?? store.lastActiveFromState()
    }

    public func activeProfile() -> FanProfile? {
        guard let name = file.active ?? store.lastActiveFromState() else { return nil }
        return file.profiles.first { $0.name == name }
    }

    // MARK: - commands

    @discardableResult
    public func useProfile(_ name: String) -> String? {
        guard file.profiles.contains(where: { $0.name == name }) else {
            return "no profile named \(name)"
        }
        clearManualOverride()
        file.active = name
        store.saveLastActive(name)
        try? store.save(file)
        applyOnce(force: true)
        return nil
    }

    @discardableResult
    public func setManual(fan: Int, rpm: Int) -> String? {
        guard fan >= 0, fan < smc.fanCount() else { return "no fan \(fan)" }
        guard let f = smc.fan(fan), rpm >= f.minRPM, rpm <= f.maxRPM else {
            return "rpm out of range"
        }
        do {
            try smc.forceFanMode(fan)
            try smc.setFanTargetRPM(fan, rpm: rpm)
            manualFanRPM[fan] = rpm
            lastTargets[fan] = rpm
            return nil
        } catch {
            return "SMC error: \(error)"
        }
    }

    @discardableResult
    public func resumeAutomatic() -> String? {
        clearManualOverride()
        var firstError: String?
        for fan in 0 ..< smc.fanCount() {
            do { try smc.restoreAutomaticMode(fan) } catch {
                if firstError == nil { firstError = "SMC error: \(error)" }
            }
        }
        lastTargets.removeAll()
        return firstError
    }

    public func shutdownNow() {
        _ = resumeAutomatic()
    }

    private func clearManualOverride() {
        manualFanRPM.removeAll()
    }

    // MARK: - loop step

    /// One control step. `force` bypasses the profile-level hysteresis skip.
    public func applyOnce(force: Bool = false) {
        guard manualFanRPM.isEmpty else { return } // manual wins until cleared
        guard let profile = activeProfile() else { return }

        let cpu = smc.maxTemperature(group: .cpu)
        let gpu = smc.maxTemperature(group: .gpu)

        for fan in smc.allFans() {
            let last = lastTargets[fan.id]
            guard let decision = ControlEngine.command(
                profile: profile, cpuTemp: cpu, gpuTemp: gpu,
                fanMin: fan.minRPM, fanMax: fan.maxRPM, lastTarget: last
            ) else { continue }
            if !force, decision.rpm == last { continue }
            do {
                try smc.forceFanMode(fan.id)
                try smc.setFanTargetRPM(fan.id, rpm: decision.rpm)
                lastTargets[fan.id] = decision.rpm
            } catch {
                FileHandle.standardError.write(Data("fannierd: \(error)\n".utf8))
            }
        }
    }
}
