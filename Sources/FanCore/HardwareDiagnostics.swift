import Darwin
import Foundation
import FanSMC

/// Read-only facts about the SMC keys and temperature sensors found on this Mac.
/// A detected write path describes key compatibility, not a successful live write.
public struct HardwareDiagnostics: Codable, Equatable, Sendable {
    public struct FanCapability: Codable, Equatable, Sendable {
        public var id: Int
        public var name: String
        public var minRPM: Int
        public var maxRPM: Int
        public var actualRPM: Int
        public var automatic: Bool
        public var modeKey: String
        public var modeType: String?
        public var modeSize: Int?
        public var targetKey: String
        public var targetType: String?
        public var targetSize: Int?
        public var supportedEncoder: Bool

        public init(
            id: Int, name: String, minRPM: Int, maxRPM: Int, actualRPM: Int,
            automatic: Bool, modeKey: String, modeType: String?, modeSize: Int?,
            targetKey: String, targetType: String?, targetSize: Int?, supportedEncoder: Bool
        ) {
            self.id = id
            self.name = name
            self.minRPM = minRPM
            self.maxRPM = maxRPM
            self.actualRPM = actualRPM
            self.automatic = automatic
            self.modeKey = modeKey
            self.modeType = modeType
            self.modeSize = modeSize
            self.targetKey = targetKey
            self.targetType = targetType
            self.targetSize = targetSize
            self.supportedEncoder = supportedEncoder
        }
    }

    public var modelIdentifier: String?
    public var macOSVersion: String
    public var architecture: String
    public var fans: [FanCapability]
    public var sensorGroups: [SensorSource]
    /// True means each fan exposes a mode and target key with a known encoding.
    public var writePathDetected: Bool
    /// Historical hardware-write evidence documented by this project.
    public var matchesDocumentedTestConfiguration: Bool

    public init(
        modelIdentifier: String?, macOSVersion: String, architecture: String,
        fans: [FanCapability], sensorGroups: [SensorSource], writePathDetected: Bool,
        matchesDocumentedTestConfiguration: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.fans = fans
        self.sensorGroups = sensorGroups
        self.writePathDetected = writePathDetected
        self.matchesDocumentedTestConfiguration = matchesDocumentedTestConfiguration
    }

    public var formattedText: String {
        var lines = [
            "fannier hardware diagnostics (read-only)",
            "Model: \(modelIdentifier ?? "unavailable")",
            "macOS: \(macOSVersion)",
            "Architecture: \(architecture)",
            "Detected SMC write-key layout: \(writePathDetected ? "supported encoding found" : "incomplete or unsupported")",
            "Historical test configuration: \(matchesDocumentedTestConfiguration ? "matches Mac17,7 / macOS 27.0.1" : "not in this project's documented hardware test matrix")",
            "This read-only report does not validate the current build's write behavior. Detected keys do not prove that a write will succeed.",
            "SMC writes require the privileged daemon.",
            "Fans:"
        ]

        if fans.isEmpty {
            lines.append("  none detected")
        } else {
            for fan in fans {
                let mode = fan.modeType.map { "\($0) x\(fan.modeSize ?? 0)" } ?? "missing"
                let target = fan.targetType.map { "\($0) x\(fan.targetSize ?? 0)" } ?? "missing"
                lines.append("  #\(fan.id) \(fan.name): \(fan.minRPM)–\(fan.maxRPM) rpm; actual \(fan.actualRPM); \(fan.automatic ? "automatic" : "manual")")
                lines.append("    \(fan.modeKey): \(mode); \(fan.targetKey): \(target); supported encoding: \(fan.supportedEncoder ? "yes" : "no")")
            }
        }

        lines.append("Temperature sensors:")
        if sensorGroups.isEmpty {
            lines.append("  none detected")
        } else {
            for group in sensorGroups {
                lines.append("  \(group.group.uppercased()): \(group.sensors.count) sensor(s); hottest \(group.hotKey) \(String(format: "%.1f", group.hotC)) °C")
                lines.append("    keys: \(group.sensors.map(\.key).joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public extension SMCConnection {
    /// Collects machine metadata and SMC capabilities without issuing writes.
    func hardwareDiagnostics() -> HardwareDiagnostics {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"

        let fanReports = allFans().map { fan -> HardwareDiagnostics.FanCapability in
            let modeKey = manualModeKey(fan.id)
            let targetKey = "F\(fan.id)Tg"
            let mode = keyInfo(modeKey)
            let target = keyInfo(targetKey)
            let supportedTarget = (target?.type == "flt " && target?.size == 4)
                || (target?.type == "fpe2" && target?.size == 2)
            let supportedMode = mode?.type == "ui8 " && mode?.size == 1
            return HardwareDiagnostics.FanCapability(
                id: fan.id, name: fan.name, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                actualRPM: fan.actualRPM, automatic: fan.automatic,
                modeKey: modeKey, modeType: mode?.type, modeSize: mode?.size,
                targetKey: targetKey, targetType: target?.type, targetSize: target?.size,
                supportedEncoder: supportedMode && supportedTarget
            )
        }

        let groups = SensorGroup.allCases.compactMap { group -> SensorSource? in
            let readings = sensorReadings(group: group)
            guard let hottest = readings.first else { return nil }
            return SensorSource(
                group: group.rawValue, hotKey: hottest.key, hotC: hottest.tempC,
                sensors: readings.map { SensorReading(key: $0.key, tempC: $0.tempC) }
            )
        }

        let model = Self.sysctlString("hw.model")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let writePathDetected = !fanReports.isEmpty && fanReports.allSatisfy(\.supportedEncoder)

        return HardwareDiagnostics(
            modelIdentifier: model, macOSVersion: osVersion, architecture: architecture,
            fans: fanReports, sensorGroups: groups, writePathDetected: writePathDetected,
            matchesDocumentedTestConfiguration: model == "Mac17,7" && osVersion == "27.0.1"
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        let sizeResult = name.withCString { sysctlbyname($0, nil, &size, nil, 0) }
        guard sizeResult == 0, size > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        let readResult = name.withCString { key in
            buffer.withUnsafeMutableBufferPointer { bytes in
                sysctlbyname(key, bytes.baseAddress, &size, nil, 0)
            }
        }
        guard readResult == 0 else { return nil }
        return String(cString: buffer)
    }
}
