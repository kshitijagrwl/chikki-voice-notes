import Foundation
import EventKit
import UserNotifications
import AppKit

/// Lightweight projection of an EKEvent so SwiftUI can bind without lugging
/// the EventKit type into the view layer.
struct UpcomingEvent: Equatable, Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let conferenceURL: String?
}

/// Polls EventKit for upcoming calendar events that contain a video-conference
/// link, and triggers auto-recording when one is about to start.
///
/// The watcher itself is fire-and-forget: enabling/disabling is driven by the
/// `auto_record_enabled` config flag and the app calls `startWatching()` /
/// `stopWatching()` accordingly.
@MainActor
final class CalendarWatcher: ObservableObject {
    static let shared = CalendarWatcher()

    // MARK: Published state

    @Published private(set) var authState: AuthState = .notDetermined
    @Published private(set) var nextMeeting: UpcomingEvent?
    @Published private(set) var isWatching: Bool = false
    /// Seconds until next meeting starts (negative if already started). Updated
    /// every poll tick. nil if no upcoming meeting.
    @Published private(set) var secondsUntilNext: Int?

    enum AuthState: Equatable {
        case notDetermined
        case denied
        case granted
    }

    // MARK: Internals

    private let store = EKEventStore()
    private var pollTimer: Timer?

    /// Cancellation id -> work item, so the user can cancel a pending auto-record
    /// during the grace window via notification action.
    private var pendingTrigger: (eventID: String, workItem: DispatchWorkItem)?
    /// Set of event IDs we've already triggered a record for this session.
    private var firedEventIDs: Set<String> = []
    /// Conference URL regex (case-insensitive).
    private static let conferenceRegex: NSRegularExpression = {
        let pattern = #"zoom\.us|meet\.google\.com|teams\.microsoft\.com|webex\.com"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let cancelActionID = "CHIKKI_CANCEL_AUTORECORD"
    private static let categoryID = "CHIKKI_AUTORECORD"

    private init() {
        registerNotificationCategory()
        refreshAuthState()
    }

    // MARK: - Auth

    private func refreshAuthState() {
        let status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            authState = .granted
        case .denied, .restricted:
            authState = .denied
        case .notDetermined:
            authState = .notDetermined
        @unknown default:
            authState = .notDetermined
        }
    }

    /// Request read access to calendars. On macOS 14+, request full access (which
    /// also implicitly grants read). On macOS 13, fall back to legacy API.
    func requestAccess() async {
        if #available(macOS 14.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                authState = granted ? .granted : .denied
            } catch {
                NSLog("CalendarWatcher: requestFullAccessToEvents failed: \(error)")
                authState = .denied
            }
        } else {
            do {
                let granted = try await store.requestAccess(to: .event)
                authState = granted ? .granted : .denied
            } catch {
                NSLog("CalendarWatcher: requestAccess failed: \(error)")
                authState = .denied
            }
        }
    }

    // MARK: - Watching lifecycle

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true

        // Kick off auth + first poll.
        Task {
            if authState != .granted {
                await requestAccess()
            }
            if authState == .granted {
                poll()
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        pollTimer?.invalidate()
        pollTimer = nil
        cancelPendingTrigger(reason: "watcher stopped")
        nextMeeting = nil
        secondsUntilNext = nil
    }

    // MARK: - Polling

    private func poll() {
        guard authState == .granted else { return }

        let now = Date()
        let horizon = now.addingTimeInterval(5 * 60) // next 5 minutes
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-60),
            end: horizon,
            calendars: nil
        )
        let events = store.events(matching: predicate)

        let requireConfLink = ConfigStore.shared.calendarRequireConfLink

        let matched = events
            .filter { ev in
                guard let _ = ev.startDate, let _ = ev.endDate else { return false }
                if ev.isAllDay { return false }
                if requireConfLink {
                    return Self.conferenceURL(in: ev) != nil
                }
                return true
            }
            .sorted { $0.startDate < $1.startDate }

        // Pick the next meeting that hasn't ended yet.
        let upcoming = matched.first(where: { $0.endDate > now })

        if let ev = upcoming {
            let url = Self.conferenceURL(in: ev)
            let projection = UpcomingEvent(
                id: ev.eventIdentifier ?? "\(ev.startDate.timeIntervalSince1970)-\(ev.title ?? "")",
                title: ev.title ?? "Untitled",
                startDate: ev.startDate,
                endDate: ev.endDate,
                conferenceURL: url
            )
            nextMeeting = projection
            secondsUntilNext = Int(ev.startDate.timeIntervalSince(now))

            maybeScheduleTrigger(for: ev, projection: projection)
        } else {
            nextMeeting = nil
            secondsUntilNext = nil
        }
    }

    private func maybeScheduleTrigger(for ev: EKEvent, projection: UpcomingEvent) {
        guard ConfigStore.shared.calendarAutoRecordEnabled else { return }
        guard !firedEventIDs.contains(projection.id) else { return }

        let lead = ConfigStore.shared.calendarLeadTimeSec
        let secondsUntilStart = ev.startDate.timeIntervalSinceNow

        // Already started (within the last minute) -> fire immediately.
        // About to start (within the lead window) -> schedule with grace period.
        // Otherwise -> wait until a future poll.
        guard secondsUntilStart <= Double(lead) else { return }

        // Skip if already in a recording or processing flow.
        if RecordingManager.shared.isRecording || RecordingManager.shared.isProcessing {
            NSLog("CalendarWatcher: skipping auto-record for '\(projection.title)' — busy")
            firedEventIDs.insert(projection.id)
            return
        }

        // Avoid double-scheduling for the same event.
        if pendingTrigger?.eventID == projection.id { return }

        firedEventIDs.insert(projection.id)
        scheduleTrigger(for: projection, leadTimeSec: max(0, min(lead, Int(max(0, secondsUntilStart)))))
    }

    private func scheduleTrigger(for projection: UpcomingEvent, leadTimeSec: Int) {
        // Post a notification with a Cancel action.
        sendStartNotification(for: projection, leadTimeSec: leadTimeSec)

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.pendingTrigger = nil
                guard ConfigStore.shared.calendarAutoRecordEnabled else { return }
                guard !RecordingManager.shared.isRecording, !RecordingManager.shared.isProcessing else {
                    NSLog("CalendarWatcher: aborting trigger — recorder busy at fire time")
                    return
                }
                NSLog("CalendarWatcher: triggering auto-record for '\(projection.title)'")
                await RecordingManager.shared.startRecording()
                self.scheduleAutoStop(for: projection)
            }
        }
        pendingTrigger = (projection.id, work)

        let delay = max(0, leadTimeSec)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }

    /// Schedules a one-shot stop at `endDate + trailingBuffer`.
    private func scheduleAutoStop(for projection: UpcomingEvent) {
        let buffer = ConfigStore.shared.calendarTrailingBufferSec
        let stopAt = projection.endDate.addingTimeInterval(TimeInterval(buffer))
        let delay = max(1, stopAt.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delay * 1000))) {
            Task { @MainActor in
                guard RecordingManager.shared.isRecording else { return }
                NSLog("CalendarWatcher: auto-stopping recording for '\(projection.title)'")
                await RecordingManager.shared.stopRecording()
            }
        }
    }

    /// Called from the notification handler when the user clicks Cancel.
    func cancelPendingTrigger(reason: String) {
        if let pending = pendingTrigger {
            pending.workItem.cancel()
            NSLog("CalendarWatcher: cancelled pending trigger for \(pending.eventID) — \(reason)")
        }
        pendingTrigger = nil
    }

    // MARK: - Notifications

    private func registerNotificationCategory() {
        let cancel = UNNotificationAction(
            identifier: Self.cancelActionID,
            title: "Cancel",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [cancel],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func sendStartNotification(for projection: UpcomingEvent, leadTimeSec: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Chikki: Auto-record in \(leadTimeSec)s"
        content.body = "Recording '\(projection.title)'. Click Cancel to skip."
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["chikki_event_id": projection.id]

        let req = UNNotificationRequest(
            identifier: "chikki-autorecord-\(projection.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Helpers

    /// Returns the first matching conference URL found in location/url/notes.
    private static func conferenceURL(in event: EKEvent) -> String? {
        let haystacks: [String] = [
            event.location ?? "",
            event.url?.absoluteString ?? "",
            event.notes ?? "",
        ]
        for hay in haystacks where !hay.isEmpty {
            let range = NSRange(hay.startIndex..., in: hay)
            if let m = conferenceRegex.firstMatch(in: hay, options: [], range: range) {
                // Best-effort: extract a URL containing the matched substring.
                if let r = Range(m.range, in: hay) {
                    return extractURL(around: hay, hitRange: r) ?? String(hay[r])
                }
            }
        }
        return nil
    }

    private static func extractURL(around text: String, hitRange: Range<String.Index>) -> String? {
        // Find whitespace boundaries surrounding the hit.
        var start = hitRange.lowerBound
        var end = hitRange.upperBound
        let whitespace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'()"))
        while start > text.startIndex {
            let prev = text.index(before: start)
            let s = String(text[prev])
            if s.rangeOfCharacter(from: whitespace) != nil { break }
            start = prev
        }
        while end < text.endIndex {
            let s = String(text[end])
            if s.rangeOfCharacter(from: whitespace) != nil { break }
            end = text.index(after: end)
        }
        let candidate = String(text[start..<end])
        return candidate.isEmpty ? nil : candidate
    }
}
