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
                case .recording:     RecordingPane()
                case .transcription: StubPane(title: "Transcription", note: "Engine + language settings coming in a future PR.")
                case .diarization:   DiarizationPane()
                case .processing:    StubPane(title: "Processing", note: "LLM provider/model & prompt tuning.")
                case .calendar:      CalendarPane()
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

// MARK: - Recording pane

private struct RecordingPane: View {
    @ObservedObject private var store = ConfigStore.shared
    @State private var systemAudio: Bool = false

    var body: some View {
        Form {
            Section("System audio") {
                Toggle("Capture system audio", isOn: $systemAudio)
                    .onChange(of: systemAudio) { _, newValue in
                        store.systemAudio = newValue
                    }
                Text("Mixes the system audio stream (e.g. Zoom, Meet, Slack huddle) with your microphone so both sides are transcribed. Uses Apple ScreenCaptureKit — requires Screen Recording permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Screen Recording permission") {
                    HStack {
                        Text("Manage in Permissions pane")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings…") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                    }
                }
            }

            Section {
                Text("When off, Chikki records the microphone only (default). When on, a stereo archive is saved (L=mic, R=system) and a mono mix is used for transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.reload()
            systemAudio = store.systemAudio
        }
    }
}

// MARK: - Diarization pane

private struct DiarizationPane: View {
    @ObservedObject private var store = ConfigStore.shared

    @State private var enabled: Bool = false
    @State private var hasMin: Bool = false
    @State private var hasMax: Bool = false
    @State private var minSpeakers: Int = 2
    @State private var maxSpeakers: Int = 4
    @State private var hasToken: Bool = false

    var body: some View {
        Form {
            Section("Speaker diarization") {
                Toggle("Label speakers in transcripts", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        store.diarizationEnabled = newValue
                    }
                Text("Uses pyannote/speaker-diarization-3.1 to split transcripts into Speaker A, B, C… by voice. Runs on the Apple Silicon MPS backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Speaker count") {
                Toggle("Set minimum speakers", isOn: $hasMin)
                    .onChange(of: hasMin) { _, on in
                        store.diarizationMinSpeakers = on ? minSpeakers : nil
                    }
                if hasMin {
                    Stepper("Minimum: \(minSpeakers)", value: $minSpeakers, in: 1...20)
                        .onChange(of: minSpeakers) { _, newValue in
                            store.diarizationMinSpeakers = newValue
                        }
                }

                Toggle("Set maximum speakers", isOn: $hasMax)
                    .onChange(of: hasMax) { _, on in
                        store.diarizationMaxSpeakers = on ? maxSpeakers : nil
                    }
                if hasMax {
                    Stepper("Maximum: \(maxSpeakers)", value: $maxSpeakers, in: 1...20)
                        .onChange(of: maxSpeakers) { _, newValue in
                            store.diarizationMaxSpeakers = newValue
                        }
                }

                Text("Leave both unset for auto-detection. Setting bounds can improve quality when you know the meeting size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("HuggingFace token") {
                LabeledContent("HF_TOKEN") {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(hasToken ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(hasToken ? "Detected in .env" : "Missing")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { hasToken = store.hasHFToken() }
                    }
                }
                Text("pyannote requires a free HuggingFace token AND acceptance of the model EULA at huggingface.co/pyannote/speaker-diarization-3.1. Add the line `HF_TOKEN=hf_…` to the project's .env file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Identification (mapping Speaker A to a real name) is a separate setting — coming in a follow-up PR.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.reload()
            enabled = store.diarizationEnabled
            if let v = store.diarizationMinSpeakers { hasMin = true; minSpeakers = v } else { hasMin = false }
            if let v = store.diarizationMaxSpeakers { hasMax = true; maxSpeakers = v } else { hasMax = false }
            hasToken = store.hasHFToken()
        }
    }
}

// MARK: - Calendar pane

private struct CalendarPane: View {
    @ObservedObject private var store = ConfigStore.shared
    @EnvironmentObject private var watcher: CalendarWatcher

    @State private var autoRecord: Bool = false
    @State private var leadTime: Int = 10
    @State private var trailingBuffer: Int = 60
    @State private var requireConfLink: Bool = true

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Form {
            Section("Auto-record") {
                Toggle("Auto-record meetings", isOn: $autoRecord)
                    .onChange(of: autoRecord) { _, newValue in
                        store.calendarAutoRecordEnabled = newValue
                        if newValue {
                            watcher.startWatching()
                        } else {
                            watcher.stopWatching()
                        }
                    }
                Text("Starts recording automatically when an upcoming calendar event begins. A 10-second grace notification lets you cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Filter") {
                Toggle("Only events with video-conference links", isOn: $requireConfLink)
                    .onChange(of: requireConfLink) { _, newValue in
                        store.calendarRequireConfLink = newValue
                    }
                Text("Matches zoom.us, meet.google.com, teams.microsoft.com, webex.com in the event's location, URL, or notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                Stepper("Lead time: \(leadTime)s", value: $leadTime, in: 0...120, step: 5)
                    .onChange(of: leadTime) { _, newValue in
                        store.calendarLeadTimeSec = newValue
                    }
                Stepper("Trailing buffer: \(trailingBuffer)s", value: $trailingBuffer, in: 0...600, step: 15)
                    .onChange(of: trailingBuffer) { _, newValue in
                        store.calendarTrailingBufferSec = newValue
                    }
                Text("Lead time is how long Chikki waits (with a Cancel option) before starting. Trailing buffer is how long recording continues past the scheduled end.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                LabeledContent("Calendar permission") {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(authColor)
                            .frame(width: 8, height: 8)
                        Text(authLabel)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if watcher.authState == .notDetermined {
                            Button("Request access") {
                                Task { await watcher.requestAccess() }
                            }
                        } else {
                            Button("Open System Settings…") {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                        }
                    }
                }

                LabeledContent("Next meeting") {
                    if let n = watcher.nextMeeting {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(n.title)
                                .lineLimit(1)
                            Text(Self.timeFormatter.string(from: n.startDate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if watcher.isWatching {
                        Text("No upcoming meetings")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Watcher disabled")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            store.reload()
            autoRecord = store.calendarAutoRecordEnabled
            leadTime = store.calendarLeadTimeSec
            trailingBuffer = store.calendarTrailingBufferSec
            requireConfLink = store.calendarRequireConfLink
        }
    }

    private var authLabel: String {
        switch watcher.authState {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Determined"
        }
    }

    private var authColor: Color {
        switch watcher.authState {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
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
