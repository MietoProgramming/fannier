import Foundation
import FanCore
import FanSMC

/// fanierd — root LaunchDaemon.
/// Applies the active profile on a timer and answers JSON requests on a
/// unix domain socket. Restores automatic fan control before exiting.
final class DaemonServer {
    private var listenFD: Int32 = -1
    private let handler: (DaemonRequest) -> DaemonProtocol.DaemonResponse
    private let handlerQueue: DispatchQueue
    private var running = true

    init(
        socketPath: String, handlerQueue: DispatchQueue,
        handler: @escaping (DaemonRequest) -> DaemonProtocol.DaemonResponse
    ) {
        self.handler = handler
        self.handlerQueue = handlerQueue

        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            fatalError("socket(AF_UNIX) failed: errno=\(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            fatalError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }

        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            fatalError("bind failed: errno=\(errno)")
        }
        chmod(socketPath, 0o666) // menu bar app runs as user
        guard listen(listenFD, 8) == 0 else {
            fatalError("listen failed: errno=\(errno)")
        }
    }

    func run() {
        log("fannierd: accept loop starting")
        while running {
            guard let fd = accept() else { break }
            log("fannierd: accepted connection fd=\(fd)")
            handlerQueue.async { [handler] in
                guard let req = Self.readRequest(fd: fd) else {
                    log("fannierd: request decode failed")
                    close(fd); return
                }
                log("fannierd: request \(req)")
                let res = handler(req)
                log("fannierd: responding ok=\(res.ok)")
                Self.writeResponse(fd: fd, response: res)
                close(fd)
            }
        }
        log("fannierd: accept loop ended")
    }

    private func accept() -> Int32? {
        let fd = Foundation.accept(listenFD, nil, nil)
        guard fd >= 0, running else { return nil }
        return fd
    }

    static func readRequest(fd: Int32) -> DaemonRequest? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let n = chunk.withUnsafeMutableBufferPointer { b -> Int in
                recv(fd, b.baseAddress, b.count, 0)
            }
            if n <= 0 { break }
            data.append(contentsOf: chunk[0 ..< n])
            if let req = DaemonProtocol.decodeRequest(data), req != .status || data.count > 2 {
                return req
            }
        }
        return DaemonProtocol.decodeRequest(data)
    }

    static func writeResponse(fd: Int32, response: DaemonProtocol.DaemonResponse) {
        let encoder = JSONEncoder()
        guard var data = try? encoder.encode(response) else { return }
        data.append(0x0A) // newline terminator so small responses flush cleanly
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
    }
}

// MARK: - bootstrap

func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
log("fannierd starting…")

let args = Dictionary(
    uniqueKeysWithValues: zip(CommandLine.arguments, CommandLine.arguments.dropFirst())
)
let pollSeconds = Double(args["--poll"] ?? "") ?? 1.0
let heartbeatSeconds = Double(args["--heartbeat"] ?? "") ?? 2.0
let socketPath = args["--socket"] ?? DaemonProtocol.socketPath

do {
    let smc = try SMCConnection()
    let store = ProfileStore()
    let controller = Controller(smc: smc, store: store, heartbeat: heartbeatSeconds)
    let controlQueue = DispatchQueue(label: "org.kamil.fannier.control", qos: .userInitiated)
    log("smc + profiles ready")
    if let error = controller.applyOnce(force: true) { log("fanierd: initial apply failed: \(error)") }
    log("initial apply done")

    let server = DaemonServer(socketPath: socketPath, handlerQueue: controlQueue) { request in
        switch request {
        case .status:
            return .okStatus(controller.currentStatus())
        case .profiles:
            return .okProfiles(controller.profileNames())
        case .profilesDetail:
            return .okProfilesDetail(controller.profileDetails())
        case .sensors:
            return .okSensors(controller.sensorSources())
        case .setProfile(let profile):
            switch controller.upsertProfile(profile) {
            case .failure(let error): return .failure(error.message)
            case .success(let outcome):
                if let error = outcome.activationError {
                    return .failure(error, profile: outcome.profile)
                }
                return .okProfile(outcome.profile)
            }
        case .deleteProfile(let name):
            if let error = controller.deleteProfile(name) { return .failure(error) }
            return .okEmpty()
        case .useProfile(let name):
            if let error = controller.useProfile(name) { return .failure(error) }
            return .okEmpty()
        case .setManual(let fan, let rpm):
            if let error = controller.setManual(fan: fan, rpm: rpm) { return .failure(error) }
            return .okEmpty()
        case .resumeAutomatic:
            if let error = controller.resumeAutomatic() { return .failure(error) }
            return .okEmpty()
        }
    }
    log("listening on \(socketPath), poll \(pollSeconds)s, heartbeat \(heartbeatSeconds)s")

    let timer = DispatchSource.makeTimerSource(queue: controlQueue)
    timer.schedule(deadline: .now() + pollSeconds, repeating: pollSeconds)
    timer.setEventHandler { controller.applyOnce() }
    timer.resume()

    // Restore automatic control on shutdown — SIGTERM/SIGINT safe exit.
    let signalQueue = DispatchQueue(label: "signals")
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        src.setEventHandler {
            timer.cancel()
            controlQueue.sync { controller.shutdownNow() }
            exit(0)
        }
        src.resume()
        sources.append(src)
    }

    server.run()
} catch {
    FileHandle.standardError.write(Data("fannierd: fatal \(error)\n".utf8))
    exit(1)
}
