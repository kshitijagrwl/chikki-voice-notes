import Foundation
import Yams

/// Loads/saves the project's `config.yaml`, preserving unknown keys via a generic
/// dictionary representation. Strongly-typed getters/setters live in extensions on
/// `ConfigStore`; everything else round-trips through `rawConfig`.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var rawConfig: [String: Any] = [:]

    let configPath: String
    let projectDir: String

    private init() {
        self.projectDir = RecordingManager.shared.projectDir
        self.configPath = "\(projectDir)/config.yaml"
        reload()
    }

    func reload() {
        guard let data = try? String(contentsOfFile: configPath, encoding: .utf8),
              let parsed = try? Yams.load(yaml: data) as? [String: Any] else {
            rawConfig = [:]
            return
        }
        rawConfig = parsed
    }

    /// Persist current `rawConfig` back to disk. Preserves all keys.
    func save() {
        do {
            let yaml = try Yams.dump(object: rawConfig, indent: 2, sortKeys: false)
            try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("ConfigStore.save failed: \(error)")
        }
    }

    // MARK: - Generic helpers

    private func section(_ name: String) -> [String: Any] {
        (rawConfig[name] as? [String: Any]) ?? [:]
    }

    private func setSection(_ name: String, _ value: [String: Any]) {
        rawConfig[name] = value
    }

    func string(_ section: String, _ key: String, default def: String = "") -> String {
        ((rawConfig[section] as? [String: Any])?[key] as? String) ?? def
    }

    func setString(_ section: String, _ key: String, _ value: String) {
        var sec = self.section(section)
        sec[key] = value
        setSection(section, sec)
        objectWillChange.send()
    }

    // MARK: - Typed accessors

    var notesDir: String {
        get { string("output", "notes_dir", default: "notes") }
        set { setString("output", "notes_dir", newValue); save() }
    }

    var recordingsDir: String {
        get { string("recording", "recordings_dir", default: "recordings") }
        set { setString("recording", "recordings_dir", newValue); save() }
    }

    var defaultMeetingType: String {
        get { string("processing", "default_type", default: "default") }
        set { setString("processing", "default_type", newValue); save() }
    }

    var llmProvider: String {
        get { string("processing", "provider", default: "gemini") }
        set { setString("processing", "provider", newValue); save() }
    }
}

// MARK: - Meeting types

struct MeetingTypeOption: Identifiable, Hashable {
    let id: String
    let name: String
}

extension ConfigStore {
    /// Reads available meeting types from `prompts/meetings.json` if present,
    /// else falls back to root `prompts.json`. Filters underscore-prefixed keys.
    func availableMeetingTypes() -> [MeetingTypeOption] {
        let candidates = [
            "\(projectDir)/prompts/meetings.json",
            "\(projectDir)/prompts.json",
        ]

        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            var out: [MeetingTypeOption] = []
            for (key, value) in obj {
                if key.hasPrefix("_") { continue }
                let display = (value as? [String: Any])?["name"] as? String ?? key
                out.append(MeetingTypeOption(id: key, name: display))
            }
            return out.sorted { $0.id < $1.id }
        }

        return [MeetingTypeOption(id: "default", name: "General")]
    }
}
