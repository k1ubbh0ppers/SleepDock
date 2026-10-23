import Foundation

/// Feed selected tasks once per delivered snapshot. Disappearance is never proof of success.
final class AgentCompletionTracker {
    private var observed = Set<String>()
    private var confirmed = Set<String>()
    private var previous = Set<String>()
    private var compromised = false

    func reset() {
        observed.removeAll(); confirmed.removeAll(); previous.removeAll(); compromised = false
    }

    func consume(tasks: [AgentTask], completedTaskIDs: Set<String>, uncertain: Bool, interrupted: Bool = false) -> Bool {
        let current = Set(tasks.map(\.id))
        guard !observed.isEmpty || !current.isEmpty else { return false }
        observed.formUnion(current)
        confirmed.formUnion(completedTaskIDs.intersection(observed))
        if !previous.subtracting(current).isSubset(of: confirmed) { compromised = true }
        if uncertain || interrupted { compromised = true }
        previous = current
        guard current.isEmpty else { return false }
        let normal = !compromised && !uncertain && !observed.isEmpty && observed.isSubset(of: confirmed)
        reset()
        return normal
    }
}

extension AgentSnapshot {
    func hasInterruption(selectedAgentIDs: Set<String>) -> Bool {
        interruptedSources.contains("*") || !interruptedSources.isDisjoint(with: selectedAgentIDs)
    }

    /// '*' denotes unreadable generic task metadata whose agent identity is unavailable.
    func hasUncertainty(selectedAgentIDs: Set<String>) -> Bool {
        guard uncertain else { return false }
        if uncertainSources.contains("*") { return true }
        guard !selectedAgentIDs.isEmpty else { return false }
        return uncertainSources.isEmpty || !uncertainSources.isDisjoint(with: selectedAgentIDs)
    }
}
