import Foundation

/// Decides whether the controller should (re)write a fan target this tick.
///
/// On Apple Silicon the SMC (`thermalmonitord`) can flip a fan back to
/// automatic mode a few seconds after a manual write, so "nothing changed"
/// is not a reason to stay silent: the daemon re-asserts on a heartbeat and
/// immediately when it reads a fan back in automatic mode.
public enum WriteGate {
    public static func shouldWrite(
        rpm: Int,
        lastTarget: Int?,
        observedTarget: Int?,
        hysteresisRPM: Int,
        emergency: Bool,
        fanIsAutomatic: Bool,
        lastWriteAt: Date?,
        now: Date,
        heartbeat: TimeInterval,
        force: Bool
    ) -> Bool {
        if force { return true }
        if fanIsAutomatic { return true } // macOS/SMC took control back
        guard let lastTarget else { return true } // never applied
        guard let observedTarget else { return true } // target could not be read
        if abs(observedTarget - rpm) > 50 { return true } // SMC lost or drifted from the requested target
        if emergency { return true }
        if abs(rpm - lastTarget) >= max(hysteresisRPM, 1) { return true }
        if let lastWriteAt, now.timeIntervalSince(lastWriteAt) >= heartbeat { return true }
        return false
    }
}

/// Pure temperature→RPM evaluation. No SMC access, fully unit-testable.
public enum ControlEngine {
    /// Interpolate the profile curve for `tempC`.
    /// - Returns nothing when the curve is unusable (< 2 points).
    public static func targetRPM(profile: FanProfile, tempC: Double) -> Int? {
        guard profile.curve.count >= 2 else { return nil }
        let points = profile.curve.sorted { $0.tempC < $1.tempC }
        if tempC <= points.first!.tempC { return points.first!.rpm }
        if tempC >= points.last!.tempC { return points.last!.rpm }
        for i in 1 ..< points.count {
            let a = points[i - 1], b = points[i]
            if tempC <= b.tempC {
                let t = (tempC - a.tempC) / max(b.tempC - a.tempC, 0.001)
                let rpm = Double(a.rpm) + t * Double(b.rpm - a.rpm)
                return Int(rpm.rounded())
            }
        }
        return points.last!.rpm
    }

    /// Decide the RPM command for the machine right now.
    public static func command(
        profile: FanProfile?,
        cpuTemp: Double?, gpuTemp: Double?,
        fanMin: Int, fanMax: Int,
        lastTarget: Int?
    ) -> (rpm: Int, emergency: Bool)? {
        guard let profile else { return nil }
        let input: Double?
        switch profile.sensor {
        case .cpu: input = cpuTemp
        case .gpu: input = gpuTemp
        case .max: input = [cpuTemp, gpuTemp].compactMap { $0 }.max()
        }
        guard let temp = input else { return nil }

        var rpm = targetRPM(profile: profile, tempC: temp) ?? fanMin
        let emergency = temp >= profile.emergencyTempC
        if emergency { rpm = fanMax }

        rpm = max(fanMin, min(rpm, fanMax))

        // Apply hysteresis: skip the write when the change is negligible.
        if let last = lastTarget, !emergency, abs(rpm - last) < profile.hysteresisRPM {
            return nil
        }
        return (rpm, emergency)
    }
}
