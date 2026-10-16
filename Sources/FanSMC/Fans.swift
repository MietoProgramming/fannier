import Foundation

public struct Fan: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let minRPM: Int
    public let maxRPM: Int
    public let actualRPM: Int
    public let targetRPM: Int?
    public let automatic: Bool

    public init(
        id: Int, name: String, minRPM: Int, maxRPM: Int,
        actualRPM: Int, targetRPM: Int?, automatic: Bool
    ) {
        self.id = id
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.automatic = automatic
    }
}

enum FanTargetEncoder {
    static func encode(type: String, rpm: Int) throws -> [UInt8] {
        switch type {
        case "flt ":
            let bits = Float(rpm).bitPattern
            return (0 ..< 4).map { byte in
                UInt8(truncatingIfNeeded: bits >> UInt32(byte * 8))
            }
        case "fpe2":
            guard rpm > 0, rpm <= 16_383 else {
                throw SMCError(operation: "target", key: "F*Tg", kernelReturn: kIOReturnBadArgument, smcResult: nil)
            }
            let fixedPoint = rpm << 2
            return [UInt8(truncatingIfNeeded: fixedPoint >> 8), UInt8(truncatingIfNeeded: fixedPoint)]
        default:
            throw SMCError(operation: "target", key: "F*Tg", kernelReturn: kIOReturnUnsupported, smcResult: nil)
        }
    }
}

extension SMCConnection {
    // Fan keys: F<id>Ac actual, F<id>Mn min, F<id>Mx max, F<id>Tg target,
    // F<id>md/<lowercase on Apple Silicon> mode (0=auto, 1=forced), FNum count.
    // Types observed on Mac17,7 (M5 Max): flt (4 B) for speeds, ui8 for mode.

    public func fanCount() -> Int {
        Int(readValue("FNum") ?? 0)
    }

    public func manualModeKey(_ id: Int) -> String {
        if archIsAppleSilicon { return keyExists("F0md") ? "F\(id)md" : "F\(id)Md" }
        return "F\(id)Md"
    }

    public var archIsAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    public func fan(_ id: Int) -> Fan? {
        guard id < fanCount() else { return nil }
        let actual = readValue("F\(id)Ac").map { Int($0) } ?? -1
        let min = readValue("F\(id)Mn").map { Int($0) } ?? 0
        let max = readValue("F\(id)Mx").map { Int($0) } ?? 0
        let modeKey = manualModeKey(id)
        let mode = read(modeKey).flatMap { r -> UInt8? in
            r.type == "ui8 " && !r.bytes.isEmpty ? r.bytes[0] : nil
        }
        let target = readValue("F\(id)Tg").map { Int($0) }
        let name = fanName(id)
        return Fan(
            id: id, name: name, minRPM: min, maxRPM: max,
            actualRPM: actual, targetRPM: target, automatic: (mode ?? 0) != 1
        )
    }

    public func allFans() -> [Fan] {
        (0 ..< fanCount()).compactMap { fan($0) }
    }

    public func fanName(_ id: Int) -> String {
        // F<id>ID is "{fds" (16 bytes); bytes 4..15 hold a padded fan name.
        guard let r = read("F\(id)ID"), r.type == "{fds", r.size >= 16 else { return "Fan #\(id)" }
        let slice = r.bytes[4 ..< 16]
        let name = String(bytes: slice, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false) ? name! : "Fan #\(id)"
    }

    public func isKeyPresent(_ name: String) -> Bool { keyExists(name) }

    /// Enter forced/manual mode for a fan. On Apple Silicon M5+ the direct
    /// `F<id>md = 1` write is accepted; no Ftst dance is needed there.
    public func forceFanMode(_ id: Int) throws {
        let key = manualModeKey(id)
        guard keyExists(key), keyExists("F\(id)Tg") else {
            throw SMCError(operation: "force", key: key, kernelReturn: kIOReturnNotFound, smcResult: nil)
        }
        try guardedRetry {
            try write(key, bytes: [0x01], size: 1)
        }
    }

    /// Back to macOS automatic control.
    public func restoreAutomaticMode(_ id: Int) throws {
        let key = manualModeKey(id)
        guard keyExists(key) else {
            throw SMCError(operation: "restore", key: key, kernelReturn: kIOReturnNotFound, smcResult: nil)
        }
        try guardedRetry {
            try write(key, bytes: [0x00], size: 1)
        }
    }

    /// Set target RPM. Fan must be in forced mode. `Tg` is `flt` on Apple
    /// Silicon, `fpe2` on Intel Macs.
    public func setFanTargetRPM(_ id: Int, rpm: Int) throws {
        guard rpm > 0 else {
            throw SMCError(operation: "target", key: "F\(id)Tg", kernelReturn: kIOReturnBadArgument, smcResult: nil)
        }
        guard let type = keyInfo("F\(id)Tg")?.type else {
            throw SMCError(operation: "target", key: "F\(id)Tg", kernelReturn: kIOReturnNotFound, smcResult: nil)
        }
        let bytes = try FanTargetEncoder.encode(type: type, rpm: rpm)
        try guardedRetry {
            try write("F\(id)Tg", bytes: bytes, size: bytes.count)
        }
    }

    /// SMC firmware can transiently refuse writes while `thermalmonitord`
    /// holds a lock; stats uses up to 10 attempts with 50 ms gaps.
    private func guardedRetry(operation: () throws -> Void, attempts: Int = 5, delayMicros: UInt32 = 50_000) throws {
        var last: Error = SMCError(operation: "retry", key: "-", kernelReturn: 0, smcResult: nil)
        for attempt in 0 ..< attempts {
            do {
                try operation()
                return
            } catch {
                last = error
                if attempt < attempts - 1 { usleep(delayMicros) }
            }
        }
        throw last
    }
}
