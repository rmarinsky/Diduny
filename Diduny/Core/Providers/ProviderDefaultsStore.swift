import Foundation

struct JobProviderSelection: Codable, Equatable, Sendable {
    var providerID: String
    /// nil = the provider's default model.
    var modelID: String?

    static let didunyCloud = JobProviderSelection(providerID: STTProviderID.didunyCloud, modelID: nil)
}

/// Per-job default provider + model. Unset or unknown values read as Diduny Cloud.
struct ProviderDefaultsStore {
    let defaults: UserDefaults
    var knownProviderIDs: Set<String> = ProviderRegistry.shared.providerIDs

    static func storageKey(for job: STTJob) -> String {
        "sttJobDefault.\(job.rawValue)"
    }

    func selection(for job: STTJob) -> JobProviderSelection {
        storedSelection(forKey: Self.storageKey(for: job)) ?? .didunyCloud
    }

    func setSelection(_ selection: JobProviderSelection, for job: STTJob) {
        setSelection(selection, forKey: Self.storageKey(for: job))
    }

    /// The raw stored value of any `sttJobDefault.*` key (also the meeting segment keys); nil when unset,
    /// unreadable or an unknown provider. `ModeDefaults` applies its own read-time defaults (ADR-0012 D4).
    func storedSelection(forKey key: String) -> JobProviderSelection? {
        guard let data = defaults.data(forKey: key),
              let selection = try? JSONDecoder().decode(JobProviderSelection.self, from: data),
              knownProviderIDs.contains(selection.providerID)
        else { return nil }
        return selection
    }

    func setSelection(_ selection: JobProviderSelection, forKey key: String) {
        // Sorted keys: the same selection always stores the same bytes, so a migration re-run is a no-op.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(selection) else { return }
        defaults.set(data, forKey: key)
    }

    /// Resets every job using `providerID` to Diduny Cloud; returns those jobs.
    func resetJobs(using providerID: String) -> [STTJob] {
        let affected = STTJob.allCases.filter { selection(for: $0).providerID == providerID }
        for job in affected {
            defaults.removeObject(forKey: Self.storageKey(for: job))
        }
        return affected
    }
}
