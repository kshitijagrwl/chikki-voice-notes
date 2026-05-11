import SwiftUI
import KeyboardShortcuts
import AVFoundation
import EventKit
import Speech
import ApplicationServices

// MARK: - Sidebar sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case recording = "Recording"
    case transcription = "Transcription"
    case diarization = "Diarization"
    case processing = "Processing"
    case calendar = "Calendar"
    case shortcuts = "Shortcuts"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general:       return "gearshape"
        case .recording:     return "mic"
        case .transcription: return "waveform"
        case .diarization:   return "person.2.wave.2"
        case .processing:    return "sparkles"
        case .calendar:      return "calendar"
        case .shortcuts:     return "keyboard"
        case .permissions:   return "lock.shield"
        case .about:         return "info.circle"
        }
    }
}

// MARK: - Root settings view (sidebar + detail)

struct SettingsView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general:       GeneralPane()
                case .recording:     StubPane(title: "Recording", note: "Coming with system audio support (#2).")
                case .transcription: StubPane(title: "Transcription", note: "Engine + language settings coming in a future PR.")
                case .diarization:   StubPane(title: "Diarization", note: "Speaker separation + identification (#1).")
                case .processing:    StubPane(title: "Processing", note: "LLM provider/model & prompt tuning.")
                case .calendar:      StubPane(title: "Calendar", note: "Auto-record from calendar events (#10).")
                case .shortcuts:     ShortcutsPane()
                case .permissions:   PermissionsPane()
                case .about:         AboutPane()
                }
            }
            .frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 440)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - Stub pane

private struct StubPane: View {
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(note)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General pane

private struct GeneralPane: View {
    @ObservedObject private var store = ConfigStore.shared

    @State private var notesDir: String = ""
    @State private var recordingsDir: String = ""
    @State private var defaultType: String = "default"
    @State private var provider: String = "gemini"

    private let providers = ["gemini", "openai", "anthropic"]

    var body: some View {
        Form {
            Section("Output") {
                LabeledContent("Notes directory") {
                    HStack {
                        TextField("notes", text: $notesDir)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.notesDir = notesDir }
                        Button("Browse…") { pick(into: $notesDir) { store.notesDir = $0 } }
                    }
                }
                LabeledContent("Recordings directory") {
                    HStack {
                        TextField("recordings", text: $recordingsDir)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.recordingsDir = recordingsDir }
                        Button("Browse…") { pick(into: $recordingsDir) { store.recordingsDir = $0 } }
                    }
                }
            }

            Section("Defaults") {
                Picker("Default meeting type", selection: $defaultType) {
                    ForEach(store.availableMeetingTypes()) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                .onChange(of: defaultType) { _, newValue in
                    store.defaultMeetingType = newValue
                }

                Picker("LLM provider", selection: $provider) {
                    ForEach(providers, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .onChange(of: provider) { _, newValue in
                    store.llmProvider = newValue
                }
            }

            Section {
                Text("Settings are written to config.yaml. API keys live in .env (not edited here).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.reload()
            notesDir = store.notesDir
            recordingsDir = store.recordingsDir
            defaultType = store.defaultMeetingType
            provider = store.llmProvider
        }
    }

    private func pick(into binding: Binding<String>, commit: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
            commit(url.path)
        }
    }
}

// MARK: - Shortcuts pane (relocated from old SettingsView)

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle Recording:", name: .toggleRecording)
                    .padding(.vertical, 4)

                KeyboardShortcuts.Recorder("Quick Process:", name: .quickProcess)
                    .padding(.vertical, 4)
            }

            Section {
                Text("Global hotkeys work even when Chikki isn't focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions pane

private enum PermState {
    case granted, denied, notDetermined

    var label: String {
        switch self {
        case .granted:        return "Granted"
        case .denied:         return "Denied"
        case .notDetermined:  return "Not Determined"
        }
    }

    var color: Color {
        switch self {
        case .granted:        return .green
        case .denied:         return .red
        case .notDetermined:  return .orange
        }
    }
}

private struct PermissionsPane: View {
    @State private var refreshToken = 0

    var body: some View {
        Form {
            Section("Privacy") {
                permissionRow(
                    name: "Microphone",
                    state: micState(),
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                )
                permissionRow(
                    name: "Screen Recording",
                    state: screenState(),
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
                permissionRow(
                    name: "Calendar",
                    state: calendarState(),
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                )
                permissionRow(
                    name: "Accessibility",
                    state: accessibilityState(),
                    url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
            }

            Section {
                HStack {
                    Text("Status reflects current authorization. Chikki does not request permissions here — open System Settings to change them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { refreshToken += 1 }
                }
            }
        }
        .formStyle(.grouped)
        .id(refreshToken)
    }

    private func permissionRow(name: String, state: PermState, url: String) -> some View {
        LabeledContent(name) {
            HStack(spacing: 10) {
                Circle().fill(state.color).frame(width: 8, height: 8)
                Text(state.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open System Settings…") {
                    if let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
        }
    }

    // MARK: Authorization state readers (no prompts)

    private func micState() -> PermState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    private func screenState() -> PermState {
        // CGPreflightScreenCaptureAccess returns true if granted, without prompting.
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        return .notDetermined
    }

    private func calendarState() -> PermState {
        let status: EKAuthorizationStatus
        if #available(macOS 14.0, *) {
            status = EKEventStore.authorizationStatus(for: .event)
        } else {
            status = EKEventStore.authorizationStatus(for: .event)
        }
        switch status {
        case .authorized, .fullAccess, .writeOnly: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func accessibilityState() -> PermState {
        // Pass options=nil — no prompt, just check.
        return AXIsProcessTrusted() ? .granted : .notDetermined
    }
}

// MARK: - About pane

private struct AboutPane: View {
    @ObservedObject private var store = ConfigStore.shared

    private var version: String {
        let dict = Bundle.main.infoDictionary
        let v = dict?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = dict?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section("Chikki") {
                LabeledContent("Version", value: version)
                Text("Local voice recording, transcription, and meeting notes for macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Paths") {
                pathRow("config.yaml", path: store.configPath)
                pathRow("Notes", path: resolvedPath(store.notesDir))
                pathRow("Recordings", path: resolvedPath(store.recordingsDir))
            }

            Section {
                Button("Reveal config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.configPath)])
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ label: String, path: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }

    private func resolvedPath(_ p: String) -> String {
        if p.hasPrefix("/") { return p }
        return "\(store.projectDir)/\(p)"
    }
}
