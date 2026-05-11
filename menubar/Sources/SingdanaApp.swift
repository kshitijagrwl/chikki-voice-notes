import SwiftUI
import KeyboardShortcuts
import UserNotifications

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .shift]))
    static let quickProcess = Self("quickProcess", default: .init(.r, modifiers: [.command, .shift, .option]))
}

@main
struct ChikkiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recorder = RecordingManager.shared
    @StateObject private var calendar = CalendarWatcher.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(recorder)
                .environmentObject(calendar)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "mic.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(recorder.isRecording ? .red : .primary)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(calendar)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            Task { await RecordingManager.shared.toggle() }
        }

        UNUserNotificationCenter.current().delegate = self

        // Kick the calendar watcher if auto-record is enabled at launch.
        Task { @MainActor in
            if ConfigStore.shared.calendarAutoRecordEnabled {
                CalendarWatcher.shared.startWatching()
            }
        }
    }

    // Show banner notifications even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        if actionID == "CHIKKI_CANCEL_AUTORECORD" {
            Task { @MainActor in
                CalendarWatcher.shared.cancelPendingTrigger(reason: "user clicked Cancel")
            }
        }
        completionHandler()
    }
}
