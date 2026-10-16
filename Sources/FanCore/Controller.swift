import Foundation
import FanSMC

/// Owns the SMC connection, the profile loop, and manual overrides.
/// Runs inside fanierd (root). The daemon main file owns the timer; this class
/// exposes evaluate()/apply()/handle() so it stays testable.
public final class Controller {
    private let smc: SMCConnection
    private let store: ProfileStore
    /// See WriteGate: the Apple Silicon SMC can drop manual mode a few
    /// seconds after a write — re-assert at least this often.
    private let heartbeat: TimeInterval

    public private(set) var file: ProfileStore.ProfilesFile
    private var lastTargets: [Int: Int] = [:]
    private var lastWriteAt: [Int: Date] = [:]
    private var lastRevertLog: [Int: Date] = [:]
    private var manualFanRPM: [Int: Int] = [:]

    public init(smc: SMCConnection, store: ProfileStore, heartbeat: TimeInterval = 2.0) {
        self.smc = smc
        self.store = store
        self.heartbeat = heartbeat
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
            guard let hot = smc.sensorReadings(group: group).first else { return nil }
            return MachineStatus.TempState(group: group.rawValue, maxC: hot.tempC, hotKey: hot.key)
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

    public func profileDetails() -> [FanProfile] { file.profiles }

    /// Validate + persist a profile (GUI editor / CLI). Reapplies immediately
    /// when the edited profile is the active one.
    @discardableResult
    public func upsertProfile(_ profile: FanProfile) -> Result<FanProfile, ProfileValidationError> {
        switch ProfileValidator.sanitize(profile) {
        case .failure(let error):
            return .failure(error)
        case .success(let clean):
            if let index = file.profiles.firstIndex(where: { $0.name == clean.name }) {
                file.profiles[index] = clean
            } else {
                file.profiles.append(clean)
            }
            try? store.save(file)
            if activeProfileName() == clean.name { applyOnce(force: true) }
            return .success(clean)
        }
    }

    @discardableResult
    public func deleteProfile(_ name: String) -> String? {
        guard file.profiles.contains(where: { $0.name == name }) else {
            return "no profile named \(name)"
        }
        file.profiles.removeAll { $0.name == name }
        if file.active == name {
            let fallback = file.profiles.first { $0.name == "Balanced" }?.name
                ?? file.profiles.first?.name
            file.active = fallback
            store.saveLastActive(fallback)
        }
        try? store.save(file)
        applyOnce(force: true)
        return nil
    }

    /// Live per-key temperature readings per group (the editor's
    /// "source of temps" display).
    public func sensorSources() -> [SensorSource] {
        SensorGroup.allCases.compactMap { group in
            let readings = smc.sensorReadings(group: group)
            guard let hot = readings.first else { return nil }
            return SensorSource(
                group: group.rawValue,
                hotKey: hot.key,
                hotC: hot.tempC,
                sensors: readings.map { SensorReading(key: $0.key, tempC: $0.tempC) }
            )
        }
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
            lastWriteAt[fan] = Date()
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
        lastWriteAt.removeAll()
        return firstError
    }

    public func shutdownNow() {
        _ = resumeAutomatic()
    }

    private func clearManualOverride() {
        manualFanRPM.removeAll()
    }

    // MARK: - loop step

    /// One control step. `force` bypasses hysteresis/heartbeat gating.
    ///
    /// Every tick also *reads* each fan's mode, so a fan the system flipped
    /// back to automatic is re-asserted immediately (not only after the next
    /// temperature change).
    public func applyOnce(force: Bool = false) {
        let now = Date()
        let fans = smc.allFans()

        if manualFanRPM.isEmpty {
            guard let profile = activeProfile() else { return }
            let cpu = smc.maxTemperature(group: .cpu)
            let gpu = smc.maxTemperature(group: .gpu)

            for fan in fans {
                guard let decision = ControlEngine.command(
                    profile: profile, cpuTemp: cpu, gpuTemp: gpu,
                    fanMin: fan.minRPM, fanMax: fan.maxRPM, lastTarget: nil
                ) else { continue }
                guard WriteGate.shouldWrite(
                    rpm: decision.rpm, lastTarget: lastTargets[fan.id],
                    hysteresisRPM: profile.hysteresisRPM, emergency: decision.emergency,
                    fanIsAutomatic: fan.automatic, lastWriteAt: lastWriteAt[fan.id],
                    now: now, heartbeat: heartbeat, force: force
                ) else { continue }
                writeTarget(fan: fan, rpm: decision.rpm, now: now)
            }
        } else {
            // Manual override: same re-assert rules (the system also takes
            // manual fans back after a while).
            for fan in fans {
                guard let target = manualFanRPM[fan.id] else { continue }
                guard WriteGate.shouldWrite(
                    rpm: target, lastTarget: lastTargets[fan.id],
                    hysteresisRPM: 0, emergency: false,
                    fanIsAutomatic: fan.automatic, lastWriteAt: lastWriteAt[fan.id],
                    now: now, heartbeat: heartbeat, force: force
                ) else { continue }
                writeTarget(fan: fan, rpm: target, now: now)
            }
        }
    }

    private func writeTarget(fan: Fan, rpm: Int, now: Date) {
        let wasForcedBefore = lastTargets[fan.id] != nil
        do {
            try smc.forceFanMode(fan.id)
            try smc.setFanTargetRPM(fan.id, rpm: rpm)
            lastTargets[fan.id] = rpm
            lastWriteAt[fan.id] = now
            if fan.automatic, wasForcedBefore {
                if let last = lastRevertLog[fan.id], now.timeIntervalSince(last) < 60 { return }
                lastRevertLog[fan.id] = now
                logLine("fanierd: fan\(fan.id) had reverted to automatic — re-asserting manual mode")
            }
        } catch {
            logLine("fanierd: \(error)")
        }
    }

    private func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
