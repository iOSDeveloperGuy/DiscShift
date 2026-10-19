import Foundation
import DiscShiftCore

/// Imports only this workflow's known settings from a single matching app in
/// the same publisher namespace. No previous product name is embedded here.
enum SettingsStore {
    static let importMarker = "settingsImportCompleted"
    static let settingKeys = [
        "handbrake", "dvdcss", "automaticShowLookup", "profile", "encoder",
        "container", "filter", "ejectAfter", "destination", "setupCompleted"
    ]

    static func standard() -> UserDefaults {
        let defaults = UserDefaults.standard
        guard let applicationID = Bundle.main.bundleIdentifier,
              !defaults.bool(forKey: importMarker) else { return defaults }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let domains = files.filter { $0.pathExtension == "plist" }.map { $0.deletingPathExtension().lastPathComponent }
        importOnce(defaults: defaults, applicationID: applicationID, domains: domains)
        return defaults
    }

    @discardableResult
    static func importOnce(defaults: UserDefaults, applicationID: String, domains: [String]) -> Bool {
        var current = defaults.persistentDomain(forName: applicationID) ?? [:]
        guard current[importMarker] as? Bool != true else { return false }
        let components = applicationID.split(separator: ".")
        guard components.count >= 3 else { return false }
        let publisher = components.dropLast().joined(separator: ".") + "."
        let candidates = Set(domains).filter {
            $0 != applicationID && $0.hasPrefix(publisher) && $0.split(separator: ".").count == components.count
        }.compactMap { domain -> [String: Any]? in
            guard let values = defaults.persistentDomain(forName: domain), matchesWorkflow(values) else { return nil }
            return values
        }
        var imported = false
        // Multiple matches are deliberately left alone instead of guessing.
        if candidates.count == 1, let previous = candidates.first {
            for key in settingKeys where current[key] == nil {
                if let value = previous[key] { current[key] = value; imported = true }
            }
        }
        current[importMarker] = true
        defaults.setPersistentDomain(current, forName: applicationID)
        return imported
    }

    private static func matchesWorkflow(_ values: [String: Any]) -> Bool {
        guard let reader = values["handbrake"] as? String, !reader.isEmpty,
              values["dvdcss"] is String, values["automaticShowLookup"] is Bool,
              let profile = values["profile"] as? String, VideoProfile(rawValue: profile) != nil,
              let filter = values["filter"] as? String, MotionFilter(rawValue: filter) != nil else { return false }
        if let encoder = values["encoder"], VideoEncoder(rawValue: encoder as? String ?? "") == nil { return false }
        if let container = values["container"], ExportContainer(rawValue: container as? String ?? "") == nil { return false }
        return true
    }
}
