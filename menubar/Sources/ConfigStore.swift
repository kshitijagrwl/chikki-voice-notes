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

    func bool(_ section: String, _ key: String, default def: Bool = false) -> Bool {
        ((rawConfig[section] as? [String: Any])?[key] as? Bool) ?? def
    }

    func setBool(_ section: String, _ key: String, _ value: Bool) {
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

    var systemAudio: Bool {
        get { bool("recording", "system_audio", default: false) }
        set { setBool("recording", "system_audio", newValue); save() }
    }

    // MARK: - Diarization

    var diarizationEnabled: Bool {
        get { bool("diarization", "enabled", default: false) }
        set { setBool("diarization", "enabled", newValue); save() }
    }

    /// nil means "auto" (no constraint).
    var diarizationMinSpeakers: Int? {
        get { (rawConfig["diarization"] as? [String: Any])?["min_speakers"] as? Int }
        set {
            var sec = self.section("diarization")
            if let v = newValue { sec["min_speakers"] = v } else { sec["min_speakers"] = NSNull() }
            rawConfig["diarization"] = sec
            objectWillChange.send()
            save()
        }
    }

    var diarizationMaxSpeakers: Int? {
        get { (rawConfig["diarization"] as? [String: Any])?["max_speakers"] as? Int }
        set {
            var sec = self.section("diarization")
            if let v = newValue { sec["max_speakers"] = v } else { sec["max_speakers"] = NSNull() }
            rawConfig["diarization"] = sec
            objectWillChange.send()
            save()
        }
    }

    var diarizationIdentify: Bool {
        get { bool("diarization", "identify", default: true) }
        set { setBool("diarization", "identify", newValue); save() }
    }

    var diarizationMatchThreshold: Double {
        get {
            let raw = (rawConfig["diarization"] as? [String: Any])?["match_threshold"]
            if let d = raw as? Double { return d }
            if let i = raw as? Int { return Double(i) }
            return 0.7
        }
        set {
            var sec = self.section("diarization")
            sec["match_threshold"] = newValue
            rawConfig["diarization"] = sec
            objectWillChange.send()
            save()
        }
    }

    /// Does `.env` at the project root contain an HF_TOKEN line?
    func hasHFToken() -> Bool {
        let envPath = "\(projectDir)/.env"
        guard let contents = try? String(contentsOfFile: envPath, encoding: .utf8) else {
            return false
        }
        for raw in contents.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            let key = line.split(separator: "=", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if key == "HF_TOKEN" || key == "HUGGINGFACE_TOKEN" {
                // Ensure a non-empty value.
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t'\""))
                    return !val.isEmpty
                }
            }
        }
        return false
    }
}

// MARK: - Speaker registry

struct SpeakerEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let embeddingPath: String
    let createdAt: String
}

extension ConfigStore {
    /// Reads `speakers/registry.json` from the project directory.
    /// Returns an empty array if the file is missing or malformed.
    func loadSpeakers() -> [SpeakerEntry] {
        let path = "\(projectDir)/speakers/registry.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let speakers = obj["speakers"] as? [[String: Any]] else {
            return []
        }
        return speakers.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let embPath = dict["embedding_path"] as? String else { return nil }
            let created = dict["created_at"] as? String ?? ""
            return SpeakerEntry(name: name, embeddingPath: embPath, createdAt: created)
        }
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
