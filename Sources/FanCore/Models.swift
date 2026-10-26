import Foundation

/// A temperature-driven fan profile.
///
/// The curve is a list of anchor points (°C → RPM), sorted ascending.
/// Temps below the first anchor use the first anchor's RPM; temps above the
/// last use the last anchor's RPM; in between the target RPM is interpolated
/// piecewise-linearly.
public struct FanProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Which temperature drives the curve.
    public var sensor: SensorChoice
    /// Optional exact SMC temperature key. When set, this overrides `sensor`.
    public var sensorKey: String?
    /// (°C, RPM) anchors. Must contain at least two points.
    public var curve: [CurvePoint]
    /// Optional per-fan overrides; fans without an override use `curve`.
    public var fanCurves: [FanCurve]?
    /// Writes only happen when the new target differs by at least this many RPM
    /// from the last applied value (reduces SMC chatter).
    public var hysteresisRPM: Int
    /// When any monitored CPU/GPU temperature reaches this, fans jump to max.
    public var emergencyTempC: Double

    public struct CurvePoint: Codable, Equatable, Sendable {
        public var tempC: Double
        public var rpm: Int

        public init(tempC: Double, rpm: Int) {
            self.tempC = tempC
            self.rpm = rpm
        }
    }

    public struct FanCurve: Codable, Equatable, Sendable, Identifiable {
        public var id: Int { fanID }
        public var fanID: Int
        public var curve: [CurvePoint]

        public init(fanID: Int, curve: [CurvePoint]) {
            self.fanID = fanID
            self.curve = curve
        }
    }

    public enum SensorChoice: String, Codable, Sendable, CaseIterable {
        case cpu
        case gpu
        case max

        public var label: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .max: return "Max(CPU,GPU)"
            }
        }
    }

    public init(
        name: String, sensor: SensorChoice, curve: [CurvePoint],
        hysteresisRPM: Int = 75, emergencyTempC: Double = 95,
        sensorKey: String? = nil, fanCurves: [FanCurve]? = nil
    ) {
        self.name = name
        self.sensor = sensor
        self.sensorKey = sensorKey
        self.curve = curve
        self.fanCurves = fanCurves
        self.hysteresisRPM = hysteresisRPM
        self.emergencyTempC = emergencyTempC
    }

    public func curve(forFanID fanID: Int?) -> [CurvePoint] {
        guard let fanID,
              let override = fanCurves?.first(where: { $0.fanID == fanID }) else {
            return curve
        }
        return override.curve
    }

    /// Built-in profiles.
    public static let builtIns: [FanProfile] = [
        FanProfile(
            name: "Quiet",
            sensor: .max,
            curve: [
                .init(tempC: 40, rpm: 2400),
                .init(tempC: 70, rpm: 3200),
                .init(tempC: 88, rpm: 5000),
                .init(tempC: 94, rpm: 6500),
            ],
            hysteresisRPM: 120, emergencyTempC: 95
        ),
        FanProfile(
            name: "Balanced",
            sensor: .max,
            curve: [
                .init(tempC: 40, rpm: 2400),
                .init(tempC: 65, rpm: 3600),
                .init(tempC: 80, rpm: 5400),
                .init(tempC: 92, rpm: 7200),
            ],
            hysteresisRPM: 100, emergencyTempC: 93
        ),
        FanProfile(
            name: "Performance",
            sensor: .max,
            curve: [
                .init(tempC: 35, rpm: 3200),
                .init(tempC: 55, rpm: 4800),
                .init(tempC: 70, rpm: 6400),
                .init(tempC: 85, rpm: 7826),
            ],
            hysteresisRPM: 60, emergencyTempC: 90
        ),
    ]
}

/// Mirror of live machine state exposed through the daemon protocol.
public struct MachineStatus: Codable, Equatable, Sendable {
    public struct FanState: Codable, Equatable, Sendable {
        public var id: Int
        public var name: String
        public var actualRPM: Int
        public var minRPM: Int
        public var maxRPM: Int
        public var automatic: Bool
        public var desiredRPM: Int?
        public var targetRPM: Int?
        public var lastConfirmedAt: Date?
        public var lastError: String?

        public init(
            id: Int, name: String, actualRPM: Int, minRPM: Int, maxRPM: Int,
            automatic: Bool, desiredRPM: Int? = nil, targetRPM: Int? = nil,
            lastConfirmedAt: Date? = nil, lastError: String? = nil
        ) {
            self.id = id
            self.name = name
            self.actualRPM = actualRPM
            self.minRPM = minRPM
            self.maxRPM = maxRPM
            self.automatic = automatic
            self.desiredRPM = desiredRPM
            self.targetRPM = targetRPM
            self.lastConfirmedAt = lastConfirmedAt
            self.lastError = lastError
        }
    }

    public struct TempState: Codable, Equatable, Sendable {
        public var group: String
        public var maxC: Double
        /// SMC key of the sensor that produced `maxC`, when known.
        public var hotKey: String?

        public init(group: String, maxC: Double, hotKey: String? = nil) {
            self.group = group
            self.maxC = maxC
            self.hotKey = hotKey
        }
    }

    public var fans: [FanState]
    public var temps: [TempState]
    public var activeProfile: String?
    public var manualOverride: Bool

    public init(fans: [FanState], temps: [TempState], activeProfile: String?, manualOverride: Bool) {
        self.fans = fans
        self.temps = temps
        self.activeProfile = activeProfile
        self.manualOverride = manualOverride
    }
}

public enum DaemonRequest: Equatable, Sendable {
    case status
    case profiles
    case profilesDetail
    case sensors
    case useProfile(String)
    case setProfile(FanProfile)
    case deleteProfile(String)
    case setManual(fan: Int, rpm: Int)
    case resumeAutomatic
}

extension DaemonRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case cmd, name, fan, rpm, profile
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status: try c.encode("status", forKey: .cmd)
        case .profiles: try c.encode("profiles", forKey: .cmd)
        case .profilesDetail: try c.encode("profilesDetail", forKey: .cmd)
        case .sensors: try c.encode("sensors", forKey: .cmd)
        case .useProfile(let name):
            try c.encode("use", forKey: .cmd)
            try c.encode(name, forKey: .name)
        case .setProfile(let profile):
            try c.encode("setProfile", forKey: .cmd)
            try c.encode(profile, forKey: .profile)
        case .deleteProfile(let name):
            try c.encode("delProfile", forKey: .cmd)
            try c.encode(name, forKey: .name)
        case .setManual(let fan, let rpm):
            try c.encode("manual", forKey: .cmd)
            try c.encode(fan, forKey: .fan)
            try c.encode(rpm, forKey: .rpm)
        case .resumeAutomatic: try c.encode("auto", forKey: .cmd)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .cmd) {
        case "status": self = .status
        case "profiles": self = .profiles
        case "profilesDetail": self = .profilesDetail
        case "sensors": self = .sensors
        case "use": self = .useProfile(try c.decode(String.self, forKey: .name))
        case "setProfile": self = .setProfile(try c.decode(FanProfile.self, forKey: .profile))
        case "delProfile": self = .deleteProfile(try c.decode(String.self, forKey: .name))
        case "manual":
            self = .setManual(
                fan: try c.decode(Int.self, forKey: .fan),
                rpm: try c.decode(Int.self, forKey: .rpm)
            )
        case "auto": self = .resumeAutomatic
        case let other:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unknown command \(other)"
                )
            )
        }
    }
}

/// One individual SMC temperature sensor reading.
public struct SensorReading: Codable, Equatable, Sendable {
    public var key: String
    public var tempC: Double

    public init(key: String, tempC: Double) {
        self.key = key
        self.tempC = tempC
    }
}

/// All readings of one sensor group plus the hottest one (the "source" that
/// currently drives Max(CPU,GPU) curves).
public struct SensorSource: Codable, Equatable, Sendable {
    public var group: String
    public var hotKey: String
    public var hotC: Double
    /// Sorted hottest first.
    public var sensors: [SensorReading]

    public init(group: String, hotKey: String, hotC: Double, sensors: [SensorReading]) {
        self.group = group
        self.hotKey = hotKey
        self.hotC = hotC
        self.sensors = sensors
    }
}
