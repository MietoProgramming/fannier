import Foundation
import FanCore
import FanSMC

// fanctl — small CLI driving the same code as the daemon/app.
// Without root: status/monitoring. Reads direct from SMC.
// sudo: can talk to fanierd (profiles, manual) even while it runs.

func help() {
    print("""
    Usage: fanctl <command>
      status          temps + fans + active profile (daemon first, else direct)
      profiles        profile names known to fanierd
      use <name>      switch active profile (via fanierd)
      manual <id> <rpm>   force RPM (via fanierd)
      auto            resume macOS automatic control (via fanierd)
      read <KEY>      raw SMC key read (e.g. read Tp0U)
      help
    """)
}

func statusLine(_ status: MachineStatus) -> String {
    var out: [String] = []
    for temp in status.temps {
        out.append("\(temp.group): \(String(format: "%.1f", temp.maxC)) °C")
    }
    for fan in status.fans {
        out.append("fan\(fan.id) '\(fan.name)': \(fan.actualRPM) rpm (min \(fan.minRPM), max \(fan.maxRPM), \(fan.automatic ? "auto" : "manual"))")
    }
    if let p = status.activeProfile { out.append("profile: \(p)") }
    if status.manualOverride { out.append("manual override active") }
    return out.joined(separator: "\n")
}

let client = DaemonClient()
let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "status", nil:
    if let response = client.send(.status), let status = response.status {
        print(statusLine(status))
    } else {
        guard let smc = try? SMCConnection() else { print("SMC unavailable"); exit(1) }
        let fans = smc.allFans().map {
            MachineStatus.FanState(id: $0.id, name: $0.name, actualRPM: $0.actualRPM,
                                   minRPM: $0.minRPM, maxRPM: $0.maxRPM, automatic: $0.automatic)
        }
        let temps = SensorGroup.allCases.compactMap { group -> MachineStatus.TempState? in
            smc.maxTemperature(group: group).map { .init(group: group.rawValue, maxC: $0) }
        }
        print(statusLine(MachineStatus(fans: fans, temps: temps, activeProfile: nil, manualOverride: false)))
        print("(fanierd not running)")
    }
case "profiles":
    guard let response = client.send(.profiles) else { print("fanierd offline"); exit(2) }
    print(response.profiles?.joined(separator: "\n") ?? "(none)")
case "use":
    guard args.indices.contains(1) else { help(); exit(1) }
    let response = client.send(.useProfile(args[1]))
    print(response.map { $0.error ?? "ok: active profile → \(args[1])" } ?? "fanierd offline")
    exit(response?.ok == true ? 0 : 2)
case "manual":
    guard args.indices.contains(2), let fan = Int(args[1]), let rpm = Int(args[2]) else { help(); exit(1) }
    let response = client.send(.setManual(fan: fan, rpm: rpm))
    print(response.map { $0.error ?? "ok: fan\(fan) → \(rpm) rpm" } ?? "fanierd offline")
    exit(response?.ok == true ? 0 : 2)
case "auto":
    let response = client.send(.resumeAutomatic)
    print(response.map { $0.error ?? "ok: automatic control resumed" } ?? "fanierd offline")
    exit(response?.ok == true ? 0 : 2)
case "read":
    guard args.indices.contains(1) else { help(); exit(1) }
    guard let smc = try? SMCConnection() else { print("SMC unavailable"); exit(1) }
    guard let r = smc.read(args[1]) else { print("key not present"); exit(2) }
    let value = SMCConnection.decode(type: r.type, bytes: r.bytes).map { String($0) } ?? "n/a"
    print("\(args[1]) [\(r.type) x\(r.size)] = \(value)")
default:
    help()
}
