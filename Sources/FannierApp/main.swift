import AppKit
import FanCore
import FanSMC
import SwiftUI

/// Menu bar app: live temps/fans are read directly via SMC (no privileges
/// needed); profile switching and manual control go through fanierd.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: DispatchSourceTimer?
    private let smc: SMCConnection?
    private let client = DaemonClient()
    private var daemonStatus: MachineStatus?
    private var knownProfiles: [String] = []
    private var store: ProfileStore?
    private var editorWindow: NSWindow?
    private var editorModel: ProfileEditorModel?

    private static let maxProfileSlots = 6
    private static let maxFanSlots = 4
    private static let profileSlotBase = 1_000
    private static let fanSlotBase = 2_000

    override init() {
        smc = try? SMCConnection()
        super.init()
        // /Library/Application Support/fannier is readable once the daemon
        // installed it; per-user fallback covers pre-install use.
        let shared = ProfileStore()
        store = FileManager.default.isReadableFile(atPath: shared.fileLocation)
            ? shared
            : ProfileStore.userFallback()
    }

    private func usableStore() -> ProfileStore {
        if let s = store,
           FileManager.default.isReadableFile(atPath: s.fileLocation) {
            return s
        }
        let fallback = ProfileStore.userFallback()
        store = fallback
        return fallback
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = buildMenu()
        statusItem.menu = menu

        let pollTimer = DispatchSource.makeTimerSource(queue: .main)
        pollTimer.schedule(deadline: .now(), repeating: 3)
        pollTimer.setEventHandler { [weak self] in self?.refresh() }
        pollTimer.resume()
        timer = pollTimer
        refresh()
        if ProcessInfo.processInfo.environment["FANNIER_OPEN_EDITOR"] == "1" {
            openEditor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
    }

    // MARK: - refresh

    private func refresh() {
        daemonStatus = client.send(.status).flatMap { $0.status }
        let cpu = daemonStatus?.temps.first { $0.group == "cpu" }?.maxC
            ?? (smc?.maxTemperature(group: .cpu))
        let gpu = daemonStatus?.temps.first { $0.group == "gpu" }?.maxC
            ?? (smc?.maxTemperature(group: .gpu))
        let maxTemp = [cpu, gpu].compactMap { $0 }.max()
        statusItem.button?.title = maxTemp.map { String(format: "%.0f°", $0) } ?? "fannier"
        updateMenuItems()
    }

    // MARK: - menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hud = NSMenuItem(title: "monitoring…", action: nil, keyEquivalent: "")
        hud.tag = 100
        menu.addItem(hud)
        menu.addItem(.separator())

        let profilesHeader = NSMenuItem(title: "Profiles (via fanierd)", action: nil, keyEquivalent: "")
        profilesHeader.isEnabled = false
        menu.addItem(profilesHeader)
        addSlotItems(to: menu, base: Self.profileSlotBase, count: Self.maxProfileSlots) { slotIndex in
            let item = NSMenuItem(title: "", action: #selector(self.useProfile(_:)), keyEquivalent: "")
            item.target = self
            item.isHidden = true
            item.indentationLevel = 1
            return item
        }
        let auto = NSMenuItem(
            title: "macOS automatic", action: #selector(resumeAutomatic), keyEquivalent: "a"
        )
        auto.target = self
        auto.indentationLevel = 1
        menu.addItem(auto)
        menu.addItem(.separator())

        let fansHeader = NSMenuItem(title: "Fans", action: nil, keyEquivalent: "")
        fansHeader.isEnabled = false
        menu.addItem(fansHeader)
        addSlotItems(to: menu, base: Self.fanSlotBase, count: Self.maxFanSlots) { _ in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isHidden = true
            item.indentationLevel = 1
            return item
        }
        menu.addItem(.separator())

        let editProfiles = NSMenuItem(
            title: "Edit profiles…", action: #selector(openEditor), keyEquivalent: "e"
        )
        editProfiles.target = self
        menu.addItem(editProfiles)

        let openConfig = NSMenuItem(
            title: "Reveal profiles.json in Finder", action: #selector(openConfigFile), keyEquivalent: "o"
        )
        openConfig.target = self
        menu.addItem(openConfig)

        let install = NSMenuItem(
            title: "Install / restart fanierd (sudo)…",
            action: #selector(installDaemon), keyEquivalent: "i"
        )
        install.target = self
        menu.addItem(install)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit fannier", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        return menu
    }

    private func addSlotItems(to menu: NSMenu, base: Int, count: Int, maker: (Int) -> NSMenuItem) {
        for i in 0 ..< count {
            let item = maker(i)
            item.tag = base + i
            menu.addItem(item)
        }
    }

    private func updateMenuItems() {
        guard let menu else { return }
        if let hud = menu.item(withTag: 100) { hud.title = hudText() }

        // Profiles
        let profiles = daemonStatus != nil
            ? (client.send(.profiles).flatMap { $0.profiles } ?? [])
            : []
        knownProfiles = profiles
        let active = daemonStatus?.activeProfile
        if profiles.isEmpty {
            if let slot = menu.item(withTag: Self.profileSlotBase) {
                slot.title = "fanierd offline — use Install…"
                slot.state = .off
                slot.isEnabled = false
                slot.isHidden = false
            }
            for i in 1 ..< Self.maxProfileSlots {
                menu.item(withTag: Self.profileSlotBase + i)?.isHidden = true
            }
        } else {
            for i in 0 ..< Self.maxProfileSlots {
                guard let slot = menu.item(withTag: Self.profileSlotBase + i) else { continue }
                if i < profiles.count {
                    let name = profiles[i]
                    slot.title = name
                    slot.representedObject = name
                    slot.state = name == active ? .on : .off
                    slot.isEnabled = true
                    slot.isHidden = false
                } else {
                    slot.isHidden = true
                }
            }
        }

        // Fans
        let fans = daemonStatus?.fans
            ?? smc?.allFans().map {
                MachineStatus.FanState(
                    id: $0.id, name: $0.name, actualRPM: $0.actualRPM,
                    minRPM: $0.minRPM, maxRPM: $0.maxRPM, automatic: $0.automatic
                )
            }
            ?? []
        for i in 0 ..< Self.maxFanSlots {
            guard let slot = menu.item(withTag: Self.fanSlotBase + i) else { continue }
            if i < fans.count {
                let fan = fans[i]
                let mode = fan.automatic ? "auto" : "manual"
                let desired = fan.desiredRPM.map { "set \($0)" } ?? "set —"
                let target = fan.targetRPM.map { "SMC \($0)" } ?? "SMC ?"
                slot.title = "\(fan.name) — \(fan.actualRPM) rpm (\(desired), \(target), \(mode))"
                slot.toolTip = fan.lastError
                slot.isHidden = false
            } else {
                slot.isHidden = true
            }
        }
    }

    private func hudText() -> String {
        var lines: [String] = []
        if let status = daemonStatus ?? readStatusDirect() {
            for temp in status.temps {
                let names: [String: String] = ["cpu": "CPU", "gpu": "GPU"]
                let source = temp.hotKey.map { " (\($0))" } ?? ""
                lines.append(String(format: "%@: %.1f °C%@", names[temp.group] ?? temp.group, temp.maxC, source))
            }
            if status.manualOverride {
                lines.append("manual override active")
            } else if let p = status.activeProfile {
                lines.append("profile: \(p)")
            }
        }
        if daemonStatus == nil { lines.append("fanierd: not running") }
        return lines.joined(separator: "\n")
    }

    private func readStatusDirect() -> MachineStatus? {
        guard let smc else { return nil }
        let fans = smc.allFans().map {
            MachineStatus.FanState(
                id: $0.id, name: $0.name, actualRPM: $0.actualRPM,
                minRPM: $0.minRPM, maxRPM: $0.maxRPM, automatic: $0.automatic
            )
        }
        guard !fans.isEmpty else { return nil }
        let temps: [MachineStatus.TempState] = SensorGroup.allCases.compactMap { group in
            guard let hot = smc.sensorReadings(group: group).first else { return nil }
            return MachineStatus.TempState(group: group.rawValue, maxC: hot.tempC, hotKey: hot.key)
        }
        return MachineStatus(fans: fans, temps: temps, activeProfile: nil, manualOverride: false)
    }

    // MARK: - actions

    @objc private func useProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        guard let response = client.send(.useProfile(name)) else {
            showActivationError("fanierd is not running")
            refresh()
            return
        }
        if !response.ok { showActivationError(response.error ?? "Could not activate \(name)") }
        refresh()
    }

    private func showActivationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not activate fan profile"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func resumeAutomatic() {
        guard let response = client.send(.resumeAutomatic) else {
            showActivationError("fanierd is not running")
            refresh()
            return
        }
        if !response.ok { showActivationError(response.error ?? "Could not resume macOS automatic control") }
        refresh()
    }

    @objc private func openConfigFile() {
        let dir = usableStore().directory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    @objc private func openEditor() {
        if editorWindow == nil {
            let model = ProfileEditorModel()
            let hosting = NSHostingController(rootView: ProfileEditorView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "fannier profiles"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 860, height: 620))
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            editorModel = model
            editorWindow = window
        }
        editorModel?.start()
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func installDaemon() {
        let scriptPath: String
        if let bundled = Bundle.main.path(forResource: "install-daemon", ofType: "sh") {
            scriptPath = bundled
        } else if let bundled = Bundle.main.path(forResource: "install-launchd", ofType: "sh") {
            scriptPath = bundled
        } else if let repoRoot = findRepoRoot() {
            scriptPath = repoRoot + "/scripts/install-launchd.sh"
        } else {
            scriptPath = "scripts/install-launchd.sh"
        }
        let appleScript = """
        do shell script "bash '\(scriptPath)'" with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
        if let error {
            let alert = NSAlert()
            alert.messageText = "Failed to install fanierd"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        refresh()
    }

    private func findRepoRoot() -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        if cwd.hasSuffix("/fannier") { return cwd }
        // dev checkout: app bundle lives at <repo>/build/fannier.app
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if bundle.hasSuffix("/build/fannier.app") {
            return String(bundle.dropLast("/build/fannier.app".count))
        }
        return nil
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === editorWindow {
            editorModel?.stop()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
