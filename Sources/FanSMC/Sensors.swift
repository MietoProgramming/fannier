import Foundation

public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu
    case gpu
}

extension SMCConnection {
    // Apple M5 sensor keys (Mac17,7 verified by direct probe):
    // - CPU dies: Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K (super) + Tp0O Tp0R Tp0U Tp0X
    //   Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y (performance clusters)
    // - GPU dies: Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c Tg1g
    // Keys are generation-specific; when the explicit list is unavailable we
    // fall back to a prefix heuristic (Tp* = CPU dies, Tg* = GPU dies).
    // Source: exelban/stats Values.swift & narugit/smctemp (M1..M5 lists).

    public func temperature(_ key: String) -> Double? {
        guard let v = readValue(key), v > 5, v < 125 else { return nil }
        return v
    }

    public func temperatures(group: SensorGroup) -> [Double] {
        sensorKeys(group: group).compactMap { temperature($0) }
    }

    /// Keys that participate in a group: the generation-specific list when
    /// present, otherwise all enumerated `Tp*`/`Tg*` keys (prefix heuristic).
    public func sensorKeys(group: SensorGroup) -> [String] {
        switch group {
        case .cpu:
            let known = ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                         "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
                         "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
            let present = known.filter { keyExists($0) }
            return present.isEmpty ? enumeratedKeys(prefix: "Tp") : present
        case .gpu:
            let known = ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
            let present = known.filter { keyExists($0) }
            return present.isEmpty ? enumeratedKeys(prefix: "Tg") : present
        }
    }

    /// Key-preserving readings, sorted hottest first — lets the UI show which
    /// individual sensor is the current "source of temps".
    public func sensorReadings(group: SensorGroup) -> [(key: String, tempC: Double)] {
        sensorKeys(group: group)
            .compactMap { key in temperature(key).map { (key, $0) } }
            .sorted { $0.tempC > $1.tempC }
    }

    public func maxTemperature(group: SensorGroup) -> Double? {
        temperatures(group: group).max()
    }

    /// Enumerated T* keys for machines whose die keys differ from the lists.
    private func enumeratedKeys(prefix: String) -> [String] {
        (allKeys()?.filter { $0.hasPrefix(prefix) } ?? [])
    }
}
