import AppKit
import ServiceManagement
import SwiftUI

/// macOS owns the persisted login item; both settings and the menu use its status.
final class LaunchAtLoginSettings: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status

    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    var canChange: Bool {
        switch status {
        case .enabled, .requiresApproval, .notRegistered: return true
        case .notFound: return false
        @unknown default: return false
        }
    }

    var statusDescription: String {
        switch status {
        case .enabled:
            return "fannier will open automatically when you log in, including after restarting your Mac."
        case .requiresApproval:
            return "Approval is needed in System Settings → General → Login Items before fannier can open automatically."
        case .notRegistered:
            return "Open fannier automatically when you log in, including after restarting your Mac."
        case .notFound:
            return "Launch fannier from the installed app in Applications to enable Open at Login."
        @unknown default:
            return "The Login Item status is unavailable. Try opening settings again."
        }
    }

    func refresh() {
        let current = SMAppService.mainApp.status
        if status != current { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        guard canChange, enabled != isRegistered else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Open at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        refresh()
    }

    func toggleFromMenu() {
        refresh()
        if status == .requiresApproval {
            openLoginItems()
        } else {
            setEnabled(!isRegistered)
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct SettingsView: View {
    @ObservedObject var loginItem: LaunchAtLoginSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Startup")
                .font(.headline)
            Toggle("Open at Login", isOn: Binding(
                get: { loginItem.isRegistered },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!loginItem.canChange)
            Text(loginItem.statusDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loginItem.status == .requiresApproval {
                Button("Open Login Items…") {
                    loginItem.openLoginItems()
                }
            }
        }
        .padding(24)
        .frame(width: 392, alignment: .leading)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}
