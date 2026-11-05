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
        guard let data = defaults.data(forKey: Self.storageKey(for: job)),
              let selection = try? JSONDecoder().decode(JobProviderSelection.self, from: data),
              knownProviderIDs.contains(selection.providerID)
        else { return .didunyCloud }
        return selection
    }

    func setSelection(_ selection: JobProviderSelection, for job: STTJob) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: Self.storageKey(for: job))
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
