import Foundation

/// Error from profile validation (message is user-presentable).
public struct ProfileValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// Pure validation/sanitizing for profiles coming from the editor or CLI.
/// The daemon applies this before persisting, so a bad GUI session can never
/// store an unusable or unsafe profile.
public enum ProfileValidator {
    public static let maxNameLength = 40
    public static let rpmHardMax = 12_000
    public static let tempRange: ClosedRange<Double> = 0 ... 120
    public static let emergencyRange: ClosedRange<Double> = 60 ... 100
    public static let hysteresisRange: ClosedRange<Int> = 0 ... 1_000

    /// Returns the cleaned profile (sorted/deduped curve, clamped bounds) or a
    /// human-readable reason why it cannot be used.
    public static func sanitize(_ profile: FanProfile) -> Result<FanProfile, ProfileValidationError> {
        var clean = profile

        clean.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.name.isEmpty else {
            return .failure(ProfileValidationError("profile name is empty"))
        }
        guard clean.name.count <= maxNameLength else {
            return .failure(ProfileValidationError("profile name is longer than \(maxNameLength) characters"))
        }

        let clamped = profile.curve.map {
            FanProfile.CurvePoint(
                tempC: min(max($0.tempC, tempRange.lowerBound), tempRange.upperBound),
                rpm: min(max($0.rpm, 0), rpmHardMax)
            )
        }.sorted { $0.tempC < $1.tempC }

        // Merge steps that share a temperature; the last definition wins.
        var deduped: [FanProfile.CurvePoint] = []
        for point in clamped {
            if let last = deduped.last, abs(last.tempC - point.tempC) < 0.001 {
                deduped[deduped.count - 1] = point
            } else {
                deduped.append(point)
            }
        }
        guard deduped.count >= 2 else {
            return .failure(ProfileValidationError("curve needs at least 2 steps with distinct temperatures"))
        }

        clean.curve = deduped
        clean.hysteresisRPM = min(max(profile.hysteresisRPM, hysteresisRange.lowerBound),
                                  hysteresisRange.upperBound)
        clean.emergencyTempC = min(max(profile.emergencyTempC, emergencyRange.lowerBound),
                                   emergencyRange.upperBound)
        return .success(clean)
    }
}
