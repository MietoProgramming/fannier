import Foundation
import FanSMC

public final class ProfileStore {
    public let directory: URL
    private let fileURL: URL
    private let stateURL: URL

    public init(directory: URL? = nil) {
        // order: explicit (CLI/daemon override) → FANNIER_PROFILES_DIR →
        // shared /Library/Application Support/fannier (daemon-visible)
        // → per-user Application Support fallback
        let base: URL
        if let directory {
            base = directory
        } else if let env = ProcessInfo.processInfo.environment["FANNIER_PROFILES_DIR"] {
            base = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: "/Library/Application Support/fannier", isDirectory: true)
        }
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("profiles.json")
        stateURL = base.appendingPathComponent("state.json")
    }

    /// Per-user store for the GUI when the shared dir is unreadable.
    public static func userFallback() -> ProfileStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("fannier", isDirectory: true)
        return ProfileStore(directory: base)
    }

    public struct ProfilesFile: Codable, Equatable, Sendable {
        public var active: String?
        /// Distinguishes explicit automatic mode from legacy state.json fallback.
        public var automaticMode: Bool
        public var profiles: [FanProfile]

        public init(active: String?, automaticMode: Bool = false, profiles: [FanProfile]) {
            self.active = active
            self.automaticMode = automaticMode
            self.profiles = profiles
        }

        private enum CodingKeys: String, CodingKey { case active, automaticMode, profiles }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            active = try container.decodeIfPresent(String.self, forKey: .active)
            automaticMode = try container.decodeIfPresent(Bool.self, forKey: .automaticMode) ?? false
            profiles = try container.decode([FanProfile].self, forKey: .profiles)
        }
    }

    public func load() -> ProfilesFile {
        guard let data = try? Data(contentsOf: fileURL) else { return defaultFile() }
        if let file = try? JSONDecoder().decode(ProfilesFile.self, from: data) {
            // keep built-ins available even if user edits the file
            var merged = file
            for b in FanProfile.builtIns where !merged.profiles.contains(where: { $0.name == b.name }) {
                merged.profiles.append(b)
            }
            return merged
        }
        return defaultFile()
    }

    public func save(_ file: ProfilesFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    public var fileLocation: String { fileURL.path }
    public var stateFileLocation: String { stateURL.path }

    private func defaultFile() -> ProfilesFile {
        ProfilesFile(active: "Balanced", profiles: FanProfile.builtIns)
    }

    // MARK: - last applied profile (used to re-apply after daemon restart)

    public func saveLastActive(_ name: String?) {
        guard let name else { return }
        try? Data("\(name)".utf8).write(to: stateURL, options: .atomic)
    }

    public func lastActiveFromState() -> String? {
        try? String(contentsOf: stateURL, encoding: .utf8)
    }
}
