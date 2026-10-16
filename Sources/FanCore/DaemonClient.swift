import Foundation

/// Wire protocol shared between the menu bar app (client) and fanierd (server).
/// JSON over a local unix domain socket: one request → one response.
public enum DaemonProtocol {
    public static let socketPath = "/var/run/fannier.sock"
    public static let version = "0.1"

    public struct DaemonResponse: Codable, Sendable {
        public var ok: Bool
        public var status: MachineStatus?
        public var profiles: [String]?
        public var profilesDetail: [FanProfile]?
        public var profile: FanProfile?
        public var sensors: [SensorSource]?
        public var error: String?
        public var version: String?

        public init(
            ok: Bool, status: MachineStatus? = nil, profiles: [String]? = nil,
            profilesDetail: [FanProfile]? = nil, profile: FanProfile? = nil,
            sensors: [SensorSource]? = nil, error: String? = nil, version: String?
        ) {
            self.ok = ok
            self.status = status
            self.profiles = profiles
            self.profilesDetail = profilesDetail
            self.profile = profile
            self.sensors = sensors
            self.error = error
            self.version = version
        }

        public static func okStatus(_ status: MachineStatus) -> DaemonResponse {
            .init(ok: true, status: status, version: DaemonProtocol.version)
        }

        public static func okProfiles(_ names: [String]) -> DaemonResponse {
            .init(ok: true, profiles: names, version: DaemonProtocol.version)
        }

        public static func okProfilesDetail(_ list: [FanProfile]) -> DaemonResponse {
            .init(ok: true, profilesDetail: list, version: DaemonProtocol.version)
        }

        public static func okProfile(_ profile: FanProfile) -> DaemonResponse {
            .init(ok: true, profile: profile, version: DaemonProtocol.version)
        }

        public static func okSensors(_ sources: [SensorSource]) -> DaemonResponse {
            .init(ok: true, sensors: sources, version: DaemonProtocol.version)
        }

        public static func okEmpty() -> DaemonResponse {
            .init(ok: true, version: DaemonProtocol.version)
        }

        public static func failure(_ message: String, profile: FanProfile? = nil) -> DaemonResponse {
            .init(ok: false, profile: profile, error: message, version: DaemonProtocol.version)
        }
    }

    public static func encodeRequest(_ request: DaemonRequest) -> Data? {
        try? JSONEncoder().encode(request)
    }

    public static func decodeRequest(_ data: Data) -> DaemonRequest? {
        try? JSONDecoder().decode(DaemonRequest.self, from: data)
    }

    public static func decodeResponse(_ data: Data) -> DaemonResponse? {
        try? JSONDecoder().decode(DaemonResponse.self, from: data)
    }
}

/// Blocking client used by the menu bar app and CLI.
public struct DaemonClient {
    public var socketPath: String
    public init(socketPath: String? = nil) {
        self.socketPath = socketPath
            ?? ProcessInfo.processInfo.environment["FANNIER_SOCKET"]
            ?? DaemonProtocol.socketPath
    }

    public func send(_ request: DaemonRequest, timeout: TimeInterval = 2.0) -> DaemonProtocol.DaemonResponse? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        guard let out = DaemonProtocol.encodeRequest(request) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }

        let connectResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        let buffer = Array(out)
        var sent = 0
        while sent < buffer.count && Date() < deadline {
            let n = buffer.withUnsafeBufferPointer { buf -> Int in
                Darwin.send(fd, buf.baseAddress! + sent, buffer.count - sent, 0)
            }
            if n <= 0 { return nil }
            sent += n
        }
        guard sent == buffer.count else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = chunk.withUnsafeMutableBufferPointer { b -> Int in
                recv(fd, b.baseAddress, b.count, 0)
            }
            if n <= 0 { break }
            response.append(contentsOf: chunk[0 ..< n])
            // server terminates every response with a newline
            if response.last == 0x0A, let parsed = DaemonProtocol.decodeResponse(response) {
                return parsed
            }
            if response.count > 1 << 20 { break }
        }
        return DaemonProtocol.decodeResponse(response)
    }
}
