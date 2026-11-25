import PlanebarCore
import SwiftUI

/// The settings window: a fixed sidebar and one page per topic.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPane?>(
                get: { model.settingsPane },
                set: { model.settingsPane = $0 ?? .account }
            )) {
                SidebarItem(title: "General", symbol: "gearshape").tag(SettingsPane.general)
                SidebarItem(title: "Account", symbol: "key").tag(SettingsPane.account)
                SidebarItem(title: "Projects", symbol: "folder").tag(SettingsPane.projects)
                SidebarItem(title: "Phases", symbol: "circle.lefthalf.filled").tag(SettingsPane.phases)
                Section {
                    SidebarItem(title: "About", symbol: "info.circle").tag(SettingsPane.about)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider().ignoresSafeArea()

            Group {
                switch model.settingsPane {
                case .general: GeneralPage()
                case .account: AccountPage()
                case .projects: ProjectsPage()
                case .phases: PhasesPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 560)
    }
}

/// A sidebar row whose icon has a fixed width, so wide and narrow symbols line up and none
/// crowds its title.
private struct SidebarItem: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).padding(.leading, 2)
        } icon: {
            Image(systemName: symbol).frame(width: 22)
        }
    }
}

/// A note under a section, left-aligned.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What Planebar last heard from Plane, in one line.
private struct ConnectionStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.connection {
        case .live: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .noKey: Text("No API key").foregroundStyle(.secondary)
        case .failed(let reason): Text(reason).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }
}

private struct AccountPage: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var isReplacing = false
    @State private var workspace = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Workspace") {
                    HStack(spacing: 8) {
                        TextField("", text: $workspace, prompt: Text("your-workspace"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit { model.setWorkspace(workspace) }
                        if workspace != model.workspace {
                            Button("Apply") { model.setWorkspace(workspace) }
                        }
                    }
                }
                LabeledContent("API key") {
                    if model.hasKey && !isReplacing {
                        HStack(spacing: 8) {
                            Label("In Keychain", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button("Replace…") { isReplacing = true }
                            Button("Remove") { model.removeKey() }
                        }
                        .disabled(DemoData.isOn)
                    } else {
                        HStack(spacing: 8) {
                            SecureField("", text: $key, prompt: Text("plane_api_…"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey)
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || model.workspace.isEmpty)
                            if model.hasKey {
                                Button("Cancel") {
                                    key = ""
                                    isReplacing = false
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Plane")
            } footer: {
                Footnote("Create a key in Plane under Profile settings → Personal access tokens.")
            }

            Section {
                LabeledContent("Status") { ConnectionStatus() }
                HStack {
                    Button("Test Connection") { model.testConnection() }
                        .disabled(!model.hasKey || model.connectionTest == .running)
                    Spacer()
                    switch model.connectionTest {
                    case .running: ProgressView().controlSize(.small)
                    case .passed(let text): Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let text): Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case nil: EmptyView()
                    }
                }
            } header: {
                Text("Connection")
            }
        }
        .formStyle(.grouped)
        .onAppear { workspace = model.workspace }
    }

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.saveKey(key)
        key = ""
        isReplacing = false
    }
}

private struct ProjectsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.projects.isEmpty {
                    HStack {
                        Text(model.hasKey ? "No projects loaded." : "Add an API key first.").foregroundStyle(.secondary)
                        Spacer()
                        if model.hasKey { Button("Reload") { model.refresh() } }
                    }
                }
                ForEach(model.projects) { project in
                    Toggle(isOn: Binding(get: { model.isChosen(project) }, set: { model.setChosen(project, $0) })) {
                        HStack(spacing: 8) {
                            Text(project.name)
                            Text(project.identifier)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } header: {
                Text("Watch these projects")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PhasesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                let phases = model.availablePhases
                if phases.isEmpty {
                    Text(model.watchedProjectIDs.isEmpty ? "Choose a project first." : "No phases loaded.")
                        .foregroundStyle(.secondary)
                }
                ForEach(phases) { phase in
                    Toggle(isOn: Binding(get: { model.isWatched(phase.name) }, set: { model.setWatched(phase.name, $0) })) {
                        HStack(spacing: 8) {
                            Image(systemName: phase.symbol).foregroundStyle(phase.colour).frame(width: 18)
                            Text(phase.name)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } header: {
                Text("Show items in")
            } footer: {
                Footnote("Phases are matched by name across projects. Approve moves an item to the next phase in its own project.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A row of swatches, the first being the menu bar's own colour, then a picker for any other.
private struct ColourChoice: View {
    @Binding var value: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LabelColour.presets, id: \.name) { preset in
                Button { value = preset.name } label: {
                    Circle()
                        .fill(Color(nsColor: preset.colour))
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle().strokeBorder(Color.primary.opacity(value == preset.name ? 0.9 : 0.15),
                                                  lineWidth: value == preset.name ? 2 : 1)
                                .padding(-3)
                                .opacity(value == preset.name ? 1 : 0)
                        }
                        .overlay { Circle().strokeBorder(Color.primary.opacity(0.15)) }
                        .padding(3)
                }
                .buttonStyle(.plain)
                .help(preset.name == "plain" ? "Menu bar colour" : preset.name.capitalized)
            }
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: LabelColour.colour(for: value)) },
                set: { value = LabelColour.hex(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Another colour")
        }
    }
}

private struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled != model.launchAtLogin { model.setLaunchAtLogin(enabled) }
                    }
                Picker("Refresh every", selection: $model.refreshMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                }
                Toggle("Notify when an item arrives", isOn: $model.notifies)
                LabeledContent("Colour when items wait") {
                    ColourChoice(value: $model.labelColour)
                }
            }

            Section {
                LabeledContent("Open Planebar") {
                    ShortcutRecorder(combo: $model.hotKey)
                }
                if model.hotKeyRefused {
                    Label("macOS refused this shortcut; another app may be using it. Try a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Shortcut")
            }

            Section {
                HStack {
                    Text("Planebar has no Dock icon; quit it here or from its menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit Planebar") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}

private struct AboutPage: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 68, height: 68)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Planebar").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Your Plane work items in the menu bar: what is waiting in each phase, approved with a click.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Footnote("A personal tool. Not affiliated with Plane.")
            }

            Section("Keyboard, with the menu open") {
                LabeledContent("Move between items", value: "↑ ↓")
                LabeledContent("Show or hide details", value: "Return, Space, → ←")
                LabeledContent("Approve", value: "A")
                LabeledContent("Undo the approval", value: "⌘Z")
                LabeledContent("Open in Plane", value: "O")
                LabeledContent("Refresh", value: "⌘R")
                LabeledContent("Settings", value: "⌘,")
                LabeledContent("Close the menu", value: "Esc")
            }
        }
        .formStyle(.grouped)
    }
}
