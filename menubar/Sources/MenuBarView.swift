import SwiftUI
import AppKit
import KeyboardShortcuts

struct MenuBarView: View {
    @EnvironmentObject var recorder: RecordingManager
    @EnvironmentObject var calendar: CalendarWatcher
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // MARK: Upcoming meeting (auto-record)

            if calendar.isWatching, let next = calendar.nextMeeting {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(countdownLabel(for: next.startDate))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()
            }

            // MARK: Primary action

            if recorder.isRecording {
                HStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("Recording: \(recorder.formattedTime)")
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                MenuRowButton("Stop Recording") {
                    Task { await recorder.stopRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

            } else if recorder.isProcessing {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Processing")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(recorder.formattedProcessingTime)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    ProcessingStepView(
                        label: "Transcribing audio",
                        state: recorder.stepState(for: "transcribing")
                    )
                    ProcessingStepView(
                        label: "Extracting notes",
                        state: recorder.stepState(for: "processing")
                    )
                    ProcessingStepView(
                        label: "Saving & exporting",
                        state: recorder.stepState(for: "saving")
                    )

                    if !recorder.processingDetail.isEmpty {
                        Text(recorder.processingDetail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minWidth: 260)

            } else {
                MenuRowButton("Start Recording") {
                    Task { await recorder.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // MARK: Last recording status

            if let lastNote = recorder.lastNote, !lastNote.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last note:")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(lastNote)
                        .font(.caption)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }

            Divider()

            // MARK: Footer actions

            MenuRowButton("Open Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                if #available(macOS 14, *) {
                    openSettings()
                } else {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut(",", modifiers: [.command])

            MenuRowButton("Quit Chikki") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .frame(width: 280)
    }
}

private func countdownLabel(for date: Date) -> String {
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 0 { return "Starting now" }
    if secs < 60 { return "Starts in \(secs)s" }
    let m = secs / 60
    let s = secs % 60
    if m < 60 {
        return String(format: "Starts in %d:%02d", m, s)
    }
    let h = m / 60
    let mm = m % 60
    return String(format: "Starts in %dh %02dm", h, mm)
}

/// Flat menubar-style row button: no chrome, full-width hover highlight.
struct MenuRowButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering ? Color.accentColor.opacity(0.18) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum StepState {
    case pending
    case active
    case done
}

struct ProcessingStepView: View {
    let label: String
    let state: StepState

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.quaternary)
                case .active:
                    ProgressView()
                        .controlSize(.mini)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 14, height: 14)

            Text(label)
                .font(.caption)
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
    }
}
