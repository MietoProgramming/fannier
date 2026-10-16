import Foundation
import FanSMC

public struct ProfileUpsertOutcome: Sendable {
    public let profile: FanProfile
    public let activationError: String?

    public init(profile: FanProfile, activationError: String?) {
        self.profile = profile
        self.activationError = activationError
    }
}

/// Owns the SMC connection, the profile loop, and manual overrides.
/// All calls must be serialized by the daemon's control queue.
public final class Controller {
    private let smc: FanControlHardware
    private let store: ProfileStore
    private let heartbeat: TimeInterval

    public private(set) var file: ProfileStore.ProfilesFile
    private var lastTargets: [Int: Int] = [:]
    private var lastWriteAt: [Int: Date] = [:]
    private var lastErrorLog: [Int: Date] = [:]
    private var manualFanRPM: [Int: Int] = [:]
    private var desiredTargets: [Int: Int] = [:]
    private var confirmedAt: [Int: Date] = [:]
    private var fanErrors: [Int: String] = [:]

    public init(smc: FanControlHardware, store: ProfileStore, heartbeat: TimeInterval = 2.0) {
        self.smc = smc
        self.store = store
        self.heartbeat = heartbeat
        self.file = store.load()
    }

    // MARK: - state

    public func currentStatus() -> MachineStatus {
        let fans = smc.allFans().map { fan in
            MachineStatus.FanState(
                id: fan.id, name: fan.name, actualRPM: fan.actualRPM,
                minRPM: fan.minRPM, maxRPM: fan.maxRPM, automatic: fan.automatic,
                desiredRPM: desiredTargets[fan.id], targetRPM: fan.targetRPM,
                lastConfirmedAt: confirmedAt[fan.id], lastError: fanErrors[fan.id]
            )
        }
        let temps: [MachineStatus.TempState] = SensorGroup.allCases.compactMap { group in
            guard let hot = smc.sensorReadings(group: group).max(by: { $0.tempC < $1.tempC }) else { return nil }
            return MachineStatus.TempState(group: group.rawValue, maxC: hot.tempC, hotKey: hot.key)
        }
        return MachineStatus(
            fans: fans, temps: temps, activeProfile: activeProfileName(),
            manualOverride: !manualFanRPM.isEmpty
        )
    }

    public func profileNames() -> [String] { file.profiles.map(\.name) }
    public func profileDetails() -> [FanProfile] { file.profiles }

    public func activeProfileName() -> String? {
        if file.automaticMode || !manualFanRPM.isEmpty { return nil }
        return file.active ?? store.lastActiveFromState()
    }

    public func activeProfile() -> FanProfile? {
        guard let name = activeProfileName() else { return nil }
        return file.profiles.first { $0.name == name }
    }

    /// Validate + persist a profile (GUI editor / CLI). Reapplies immediately
    /// when the edited profile is the active one.
    @discardableResult
    public func upsertProfile(_ profile: FanProfile) -> Result<ProfileUpsertOutcome, ProfileValidationError> {
        switch ProfileValidator.sanitize(profile) {
        case .failure(let error): return .failure(error)
        case .success(let clean):
            let previous = file
            if let index = file.profiles.firstIndex(where: { $0.name == clean.name }) {
                file.profiles[index] = clean
            } else {
                file.profiles.append(clean)
            }
            do { try store.save(file) } catch {
                file = previous
                return .failure(ProfileValidationError("could not save profiles: \(error.localizedDescription)"))
            }
            let activationError = activeProfileName() == clean.name ? applyOnce(force: true) : nil
            return .success(ProfileUpsertOutcome(profile: clean, activationError: activationError))
        }
    }

    @discardableResult
    public func deleteProfile(_ name: String) -> String? {
        guard file.profiles.contains(where: { $0.name == name }) else { return "no profile named \(name)" }
        let previous = file
        file.profiles.removeAll { $0.name == name }
        if file.active == name {
            file.active = file.profiles.first(where: { $0.name == "Balanced" })?.name
                ?? file.profiles.first?.name
            file.automaticMode = file.active == nil
        }
        do { try store.save(file) } catch {
            file = previous
            return "could not save profiles: \(error.localizedDescription)"
        }
        if file.active != previous.active { store.saveLastActive(file.active) }
        return applyOnce(force: true)
    }

    /// Live per-key temperature readings per group (the editor's display).
    public func sensorSources() -> [SensorSource] {
        SensorGroup.allCases.compactMap { group in
            let readings = smc.sensorReadings(group: group).sorted { $0.tempC > $1.tempC }
            guard let hot = readings.first else { return nil }
            return SensorSource(
                group: group.rawValue, hotKey: hot.key, hotC: hot.tempC,
                sensors: readings.map { SensorReading(key: $0.key, tempC: $0.tempC) }
            )
        }
    }

    // MARK: - commands

    @discardableResult
    public func useProfile(_ name: String) -> String? {
        guard file.profiles.contains(where: { $0.name == name }) else { return "no profile named \(name)" }
        let previous = file
        file.active = name
        file.automaticMode = false
        do { try store.save(file) } catch {
            file = previous
            return "could not save profiles: \(error.localizedDescription)"
        }
        store.saveLastActive(name)
        manualFanRPM.removeAll()
        logLine("fanierd: activating profile '\(name)'")
        return applyOnce(force: true)
    }

    @discardableResult
    public func setManual(fan: Int, rpm: Int) -> String? {
        guard fan >= 0, fan < smc.fanCount() else { return "no fan \(fan)" }
        guard let current = smc.fan(fan), rpm >= current.minRPM, rpm <= current.maxRPM else {
            return "rpm out of range"
        }
        manualFanRPM[fan] = rpm
        desiredTargets[fan] = rpm
        let error = writeAndConfirm(fan: current, rpm: rpm, forceMode: true)
        return error
    }

    @discardableResult
    public func resumeAutomatic() -> String? {
        let previous = file
        file.active = nil
        file.automaticMode = true
        do { try store.save(file) } catch {
            file = previous
            return "could not save automatic mode: \(error.localizedDescription)"
        }
        manualFanRPM.removeAll()
        desiredTargets.removeAll()
        lastTargets.removeAll()
        lastWriteAt.removeAll()
        confirmedAt.removeAll()
        let error = restoreAutomaticFans()
        logLine("fanierd: macOS automatic control requested")
        return error
    }

    /// Restore hardware mode on shutdown while preserving the selected profile
    /// for the next daemon launch.
    public func shutdownNow() {
        manualFanRPM.removeAll()
        desiredTargets.removeAll()
        lastTargets.removeAll()
        lastWriteAt.removeAll()
        confirmedAt.removeAll()
        _ = restoreAutomaticFans()
        logLine("fanierd: restored automatic mode during shutdown")
    }

    private func restoreAutomaticFans() -> String? {
        var firstError: String?
        for fan in smc.allFans() {
            do {
                try smc.restoreAutomaticMode(fan.id)
                fanErrors.removeValue(forKey: fan.id)
            } catch {
                let message = "fan\(fan.id): could not restore automatic mode: \(error)"
                fanErrors[fan.id] = message
                if firstError == nil { firstError = message }
                logThrottled(message, fan: fan.id, now: Date())
            }
        }
        return firstError
    }

    // MARK: - loop step

    /// Apply the selected profile. Returns the first per-fan verification error.
    @discardableResult
    public func applyOnce(force: Bool = false) -> String? {
        if !manualFanRPM.isEmpty {
            var firstError: String?
            let now = Date()
            for fan in smc.allFans() {
                guard let rpm = manualFanRPM[fan.id] else { continue }
                desiredTargets[fan.id] = rpm
                if WriteGate.shouldWrite(
                    rpm: rpm, lastTarget: lastTargets[fan.id], observedTarget: fan.targetRPM,
                    hysteresisRPM: 0, emergency: false, fanIsAutomatic: fan.automatic,
                    lastWriteAt: lastWriteAt[fan.id], now: now, heartbeat: heartbeat, force: force
                ) {
                    let error = writeAndConfirm(
                        fan: fan, rpm: rpm,
                        forceMode: force || fan.automatic || lastTargets[fan.id] == nil
                    )
                    if firstError == nil { firstError = error }
                }
            }
            return firstError
        }
        if file.automaticMode { return reassertAutomaticModeIfNeeded() }
        guard let profile = activeProfile() else { return nil }
        let cpu = smc.maxTemperature(group: .cpu)
        let gpu = smc.maxTemperature(group: .gpu)
        guard let decision = ControlEngine.command(
            profile: profile, cpuTemp: cpu, gpuTemp: gpu,
            fanMin: 0, fanMax: ProfileValidator.rpmHardMax, lastTarget: nil
        ) else {
            let message = "profile '\(profile.name)' has no readable temperature source"
            for fan in smc.allFans() { fanErrors[fan.id] = message }
            return message
        }

        var firstError: String?
        let now = Date()
        let fans = smc.allFans()
        guard !fans.isEmpty else { return "no fans reported by SMC" }
        for fan in fans {
            let rpm = max(fan.minRPM, min(decision.rpm, fan.maxRPM))
            desiredTargets[fan.id] = rpm
            let shouldWrite = WriteGate.shouldWrite(
                rpm: rpm, lastTarget: lastTargets[fan.id], observedTarget: fan.targetRPM,
                hysteresisRPM: profile.hysteresisRPM, emergency: decision.emergency,
                fanIsAutomatic: fan.automatic, lastWriteAt: lastWriteAt[fan.id],
                now: now, heartbeat: heartbeat, force: force
            )
            if shouldWrite {
                let error = writeAndConfirm(
                    fan: fan, rpm: rpm,
                    forceMode: force || fan.automatic || lastTargets[fan.id] == nil
                )
                if firstError == nil { firstError = error }
            } else if lastTargets[fan.id] == nil {
                let error = "fan\(fan.id): no confirmed target"
                fanErrors[fan.id] = error
                if firstError == nil { firstError = error }
            }
        }
        return firstError
    }

    private func reassertAutomaticModeIfNeeded() -> String? {
        var firstError: String?
        for fan in smc.allFans() {
            if fan.automatic {
                fanErrors.removeValue(forKey: fan.id)
                continue
            }
            do {
                try smc.restoreAutomaticMode(fan.id)
                fanErrors.removeValue(forKey: fan.id)
            } catch {
                let message = "fan\(fan.id): could not restore automatic mode: \(error)"
                fanErrors[fan.id] = message
                if firstError == nil { firstError = message }
                logThrottled(message, fan: fan.id, now: Date())
            }
        }
        return firstError
    }

    private func writeAndConfirm(fan: Fan, rpm: Int, forceMode: Bool) -> String? {
        desiredTargets[fan.id] = rpm
        let hadConfirmedTarget = lastTargets[fan.id] != nil
        var observedMode = fan.automatic
        var observedTarget = fan.targetRPM
        var lastError: String?

        for attempt in 0 ..< 3 {
            do {
                if forceMode || observedMode { try smc.forceFanMode(fan.id) }
                try smc.setFanTargetRPM(fan.id, rpm: rpm)
                guard let readBack = smc.fan(fan.id) else {
                    throw FanControlError.readBackUnavailable(fan: fan.id, requested: rpm)
                }
                observedMode = readBack.automatic
                observedTarget = readBack.targetRPM
                if !observedMode, let target = observedTarget, abs(target - rpm) <= 50 {
                    let now = Date()
                    lastTargets[fan.id] = rpm
                    lastWriteAt[fan.id] = now
                    confirmedAt[fan.id] = now
                    fanErrors.removeValue(forKey: fan.id)
                    if fan.automatic, hadConfirmedTarget {
                        logThrottled("fan\(fan.id) had reverted to automatic — re-asserting manual mode", fan: fan.id, now: now)
                    }
                    return nil
                }
                lastError = "requested \(rpm) rpm; read back mode=\(observedMode ? "auto" : "manual"), target=\(observedTarget.map(String.init) ?? "unavailable") rpm"
            } catch {
                lastError = "write/read-back failed: \(error)"
                if let readBack = smc.fan(fan.id) {
                    observedMode = readBack.automatic
                    observedTarget = readBack.targetRPM
                }
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }

        let message = "fan\(fan.id): could not confirm \(rpm) rpm after 3 attempts (read back \(observedTarget.map(String.init) ?? "unavailable") rpm, mode \(observedMode ? "auto" : "manual")); \(lastError ?? "unknown error")"
        fanErrors[fan.id] = message
        logThrottled(message, fan: fan.id, now: Date())
        return message
    }

    private func logThrottled(_ line: String, fan: Int, now: Date) {
        if let last = lastErrorLog[fan], now.timeIntervalSince(last) < 60 { return }
        lastErrorLog[fan] = now
        logLine("fanierd: \(line)")
    }

    private func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

private enum FanControlError: Error, CustomStringConvertible {
    case readBackUnavailable(fan: Int, requested: Int)

    var description: String {
        switch self {
        case let .readBackUnavailable(fan, requested):
            return "fan\(fan) read-back unavailable after requesting \(requested) rpm"
        }
    }
}
