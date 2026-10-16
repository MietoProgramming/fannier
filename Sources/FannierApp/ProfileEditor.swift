import AppKit
import FanCore
import SwiftUI

/// Editor state. Talks to fanierd over the unix socket, keeps an editable
/// copy (draft) of the selected profile, and polls live sensor readings while
/// the window is open so the user can see the actual source of temperatures.
final class ProfileEditorModel: ObservableObject {
    @Published var profiles: [FanProfile] = []
    @Published var selectedName: String?
    @Published var draft = FanProfile(name: "", sensor: .max, curve: [])
    @Published var hasDraft = false
    @Published var sensors: [SensorSource] = []
    @Published var activeName: String?
    @Published var fanMin = 0
    @Published var fanMax = 0
    @Published var online = false
    @Published var validationError: String?
    @Published var message: String?

    private let client = DaemonClient()
    private var originalDraft: FanProfile?
    private var timer: Timer?
    private var tickCount = 0

    let builtinNames = Set(FanProfile.builtIns.map(\.name))

    // MARK: - lifecycle

    func start() {
        timer?.invalidate()
        refreshAll()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.3
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - daemon sync

    func refreshAll() {
        refreshProfiles()
        if let status = client.send(.status)?.status {
            activeName = status.activeProfile
            if let fan = status.fans.first {
                fanMin = fan.minRPM
                fanMax = fan.maxRPM
            }
        }
        tick()
    }

    private func refreshProfiles() {
        if let response = client.send(.profilesDetail), let list = response.profilesDetail {
            online = true
            profiles = list
            if let name = selectedName, !profiles.contains(where: { $0.name == name }) {
                selectedName = nil
            }
        } else {
            online = false
        }
    }

    private func tick() {
        if let response = client.send(.sensors), let list = response.sensors {
            sensors = list
        }
        tickCount += 1
        if tickCount % 4 == 0, let status = client.send(.status)?.status {
            activeName = status.activeProfile
        }
    }

    // MARK: - selection

    func select(_ name: String) {
        guard let profile = profiles.first(where: { $0.name == name }) else { return }
        selectedName = name
        draft = profile
        originalDraft = profile
        hasDraft = true
        validationError = nil
        message = nil
    }

    func newProfile() {
        let profile = FanProfile(
            name: uniqueName("My profile"),
            sensor: .max,
            curve: [
                .init(tempC: 40, rpm: fanMin > 0 ? fanMin : 2_400),
                .init(tempC: 70, rpm: fanMin > 0 && fanMax > 0 ? (fanMin + fanMax) / 2 : 4_000),
                .init(tempC: 90, rpm: fanMax > 0 ? fanMax : 7_000),
            ]
        )
        selectedName = nil
        draft = profile
        originalDraft = nil
        hasDraft = true
        validationError = nil
        message = "new profile — edit and save"
    }

    func duplicateSelected() {
        guard hasDraft else { return }
        var copy = draft
        copy.name = uniqueName(draft.name + " copy")
        selectedName = nil
        draft = copy
        originalDraft = nil
        validationError = nil
        message = "duplicate — edit and save"
    }

    private func uniqueName(_ base: String) -> String {
        var candidate = base
        var n = 2
        while profiles.contains(where: { $0.name == candidate }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - mutations

    var isDirty: Bool { draft != originalDraft }
    var isBuiltinSelected: Bool {
        (selectedName.map { builtinNames.contains($0) } ?? false)
    }
    var canActivate: Bool {
        hasDraft && !isDirty && profiles.contains(where: { $0.name == draft.name })
            && activeName != draft.name
    }

    var localValidation: String? {
        if case .failure(let error) = ProfileValidator.sanitize(draft) { return error.message }
        return nil
    }

    func addStep() {
        if let last = draft.curve.max(by: { $0.tempC < $1.tempC }) {
            draft.curve.append(.init(tempC: min(last.tempC + 5, 110), rpm: last.rpm))
        } else {
            draft.curve.append(.init(tempC: 60, rpm: max(fanMin, 2_400)))
        }
        message = nil
    }

    func removeStep(_ index: Int) {
        guard draft.curve.indices.contains(index) else { return }
        draft.curve.remove(at: index)
    }

    func sortSteps() {
        draft.curve.sort { $0.tempC < $1.tempC }
    }

    func revert() {
        if let originalDraft {
            draft = originalDraft
            validationError = nil
            message = "changes reverted"
        }
    }

    func save() {
        guard hasDraft else { return }
        switch ProfileValidator.sanitize(draft) {
        case .failure(let error):
            validationError = error.message
            return
        case .success(let clean):
            let response = client.send(.setProfile(clean))
            guard let response else {
                validationError = "fanierd is not running"
                return
            }
            guard let saved = response.profile else {
                validationError = response.error ?? "profile save failed"
                return
            }
            // Renaming a custom profile: drop the old entry. Built-ins keep
            // their name (saving under a new name creates a copy).
            if let old = originalDraft?.name, old != saved.name, !builtinNames.contains(old) {
                _ = client.send(.deleteProfile(old))
            }
            validationError = response.ok ? nil : (response.error ?? "Could not activate the saved profile")
            message = response.ok ? "saved" : nil
            selectedName = saved.name
            draft = saved
            originalDraft = saved
            refreshProfiles()
        }
    }

    func deleteSelected() {
        guard let name = selectedName, !isBuiltinSelected else { return }
        guard let response = client.send(.deleteProfile(name)) else {
            message = "fanierd is not running"
            return
        }
        guard response.ok else {
            message = response.error ?? "delete failed"
            return
        }
        refreshProfiles()
        if let first = profiles.first { select(first.name) } else {
            selectedName = nil
            hasDraft = false
        }
    }

    func activate(_ name: String) {
        guard let response = client.send(.useProfile(name)) else {
            message = "fanierd is not running"
            return
        }
        if response.ok {
            activeName = name
            validationError = nil
            message = "active profile → \(name)"
        } else {
            validationError = response.error ?? "Could not activate \(name)"
            message = nil
        }
    }

    // MARK: - live readings

    var cpuSource: SensorSource? { sensors.first { $0.group == "cpu" } }
    var gpuSource: SensorSource? { sensors.first { $0.group == "gpu" } }

    var currentInputTemp: Double? {
        let cpu = cpuSource?.hotC
        let gpu = gpuSource?.hotC
        switch draft.sensor {
        case .cpu: return cpu
        case .gpu: return gpu
        case .max: return [cpu, gpu].compactMap { $0 }.max()
        }
    }

    var currentTargetRPM: Int? {
        guard let temp = currentInputTemp else { return nil }
        guard let rpm = ControlEngine.targetRPM(profile: draft, tempC: temp) else { return nil }
        let lo = fanMin > 0 ? fanMin : 0
        let hi = fanMax > 0 ? fanMax : ProfileValidator.rpmHardMax
        return min(max(rpm, lo), hi)
    }
}

// MARK: - views

struct ProfileEditorView: View {
    @ObservedObject var model: ProfileEditorModel

    var body: some View {
        HStack(spacing: 0) {
            profileList
            Divider()
            detail
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Profiles")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.profiles, id: \.name) { profile in
                        HStack(spacing: 6) {
                            Image(systemName: profile.name == model.activeName
                                  ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(profile.name == model.activeName
                                                 ? Color.accentColor : Color.secondary)
                            Text(profile.name)
                            Spacer()
                            if model.builtinNames.contains(profile.name) {
                                Text("built-in")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(profile.name == model.selectedName
                                      ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(profile.name) }
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.newProfile()
                } label: { Image(systemName: "plus") }
                    .help("New profile")
                Button("Duplicate") { model.duplicateSelected() }
                    .disabled(!model.hasDraft)
                    .help("Copy the edited profile")
                Spacer()
                Button {
                    model.deleteSelected()
                } label: { Image(systemName: "trash") }
                    .disabled(model.selectedName == nil || model.isBuiltinSelected)
                    .help("Delete profile (custom profiles only)")
            }
            .padding(8)
        }
        .frame(width: 220)
    }

    @ViewBuilder private var detail: some View {
        if model.hasDraft {
            editor
        } else {
            VStack(spacing: 8) {
                if model.online {
                    Text("Select a profile on the left, or create a new one.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("fanierd is not running")
                        .font(.headline)
                    Text("Install / restart it from the menu bar icon, then reopen this window.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                profileSection
                sourceSection
                curveSection
                advancedSection
                saveBar
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: sections

    private var profileSection: some View {
        GroupBox("Profile") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Name:")
                    TextField("name", text: $model.draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
                if model.isBuiltinSelected {
                    Text("Built-in profile — saving keeps the name; a new name saves a copy instead of renaming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var sourceSection: some View {
        GroupBox("Temperature source") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Drives the curve:", selection: $model.draft.sensor) {
                        ForEach(FanProfile.SensorChoice.allCases, id: \.self) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                    Spacer()
                    if let temp = model.currentInputTemp, let rpm = model.currentTargetRPM {
                        Text(String(format: "now: %.1f °C → %d rpm", temp, rpm))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                sensorLines
                DisclosureGroup("All sensors (\(model.cpuSource?.sensors.count ?? 0) CPU, \(model.gpuSource?.sensors.count ?? 0) GPU)") {
                    sensorGrid
                }
                .font(.caption)
            }
            .padding(6)
        }
    }

    private var sensorLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.sensors, id: \.group) { source in
                HStack(spacing: 6) {
                    Text(source.group.uppercased())
                        .font(.caption.bold())
                        .frame(width: 34, alignment: .leading)
                    Image(systemName: "flame")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("hottest: \(source.hotKey) \(String(format: "%.1f", source.hotC)) °C")
                        .monospacedDigit()
                    Text("(\(source.sensors.count) sensors)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if model.sensors.isEmpty {
                Text("waiting for fanierd…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sensorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading) {
            ForEach(model.sensors, id: \.group) { source in
                ForEach(source.sensors, id: \.key) { reading in
                    HStack(spacing: 4) {
                        Text(reading.key).foregroundStyle(.secondary)
                        Text(String(format: "%.1f °C", reading.tempC)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.top, 4)
    }

    private var curveSection: some View {
        GroupBox("Curve — temperature → fan RPM") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("\(model.draft.curve.count) steps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.fanMin > 0 || model.fanMax > 0 {
                        Text("(hardware range \(model.fanMin)–\(model.fanMax) rpm; values are clamped to it when applied)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sort by temp") { model.sortSteps() }
                    Button {
                        model.addStep()
                    } label: {
                        Label("Add step", systemImage: "plus")
                    }
                }
                ForEach(model.draft.curve.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("#\(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                        Text("below")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("temp", value: $model.draft.curve[index].tempC, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("°C →")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("rpm", value: $model.draft.curve[index].rpm, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 76)
                        Text("rpm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.removeStep(index)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove step")
                    }
                }
                CurveChart(
                    curve: model.draft.curve,
                    currentTemp: model.currentInputTemp,
                    fanMin: model.fanMin,
                    fanMax: model.fanMax
                )
            }
            .padding(6)
        }
    }

    private var advancedSection: some View {
        GroupBox("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hysteresis:")
                    TextField("rpm", value: $model.draft.hysteresisRPM, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("rpm — skip rewrites smaller than this")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Emergency temp:")
                    TextField("°C", value: $model.draft.emergencyTempC, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("°C — fans jump to maximum at this reading (kept ≤ 100 °C)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasDraft || (!model.isDirty && model.profiles.contains(where: { $0.name == model.draft.name })))
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                Button("Activate") { model.activate(model.draft.name) }
                    .disabled(!model.canActivate)
                if model.isDirty {
                    Text("unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let error = model.validationError ?? model.localValidation {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Small line chart of the curve with a marker for the current input temp.
struct CurveChart: View {
    let curve: [FanProfile.CurvePoint]
    let currentTemp: Double?
    let fanMin: Int
    let fanMax: Int

    var body: some View {
        GeometryReader { geo in
            let points = curve.sorted { $0.tempC < $1.tempC }
            let tLo = domainLow(points), tHi = domainHigh(points)
            let rHi = max(Double(points.map(\.rpm).max() ?? 1_000), Double(max(fanMax, 1_000)))
            ZStack {
                ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height * fraction))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * fraction))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                }
                if let t = currentTemp {
                    Path { p in
                        let x = px(t, in: geo.size, tLo: tLo, tHi: tHi)
                        p.move(to: CGPoint(x: x, y: 0))
                        p.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    .stroke(Color.orange.opacity(0.7),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                Path { p in
                    for (i, point) in points.enumerated() {
                        let x = px(point.tempC, in: geo.size, tLo: tLo, tHi: tHi)
                        let y = py(Double(point.rpm), in: geo.size, rHi: rHi)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 2)
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .position(
                            x: px(point.tempC, in: geo.size, tLo: tLo, tHi: tHi),
                            y: py(Double(point.rpm), in: geo.size, rHi: rHi)
                        )
                }
            }
        }
        .frame(height: 150)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .overlay(alignment: .bottomLeading) {
            Text(String(format: "%.0f °C", domainLow(curve.sorted { $0.tempC < $1.tempC })))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("\(Int(max(Double(curve.map(\.rpm).max() ?? 0), Double(max(fanMax, 1_000))))) rpm")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }

    private func domainLow(_ points: [FanProfile.CurvePoint]) -> Double {
        let low = points.map(\.tempC).min() ?? 40
        return min(low, (currentTemp ?? low)) - 5
    }

    private func domainHigh(_ points: [FanProfile.CurvePoint]) -> Double {
        let high = points.map(\.tempC).max() ?? 90
        return max(high, currentTemp ?? high) + 5
    }

    private func px(_ t: Double, in size: CGSize, tLo: Double, tHi: Double) -> CGFloat {
        let clamped = min(max(t, tLo), tHi)
        return CGFloat((clamped - tLo) / max(tHi - tLo, 1)) * size.width
    }

    private func py(_ rpm: Double, in size: CGSize, rHi: Double) -> CGFloat {
        let clamped = min(max(rpm, 0), rHi)
        return size.height - CGFloat(clamped / max(rHi, 1)) * size.height
    }
}
