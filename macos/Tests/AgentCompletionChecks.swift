import Foundation

@main
struct AgentCompletionChecks {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func task(_ id: String, _ agent: String = "codex") -> AgentTask {
        AgentTask(id: id, name: id, startedAt: Date(), source: agent, agentID: agent)
    }
    static func main() {
        let tracker = AgentCompletionTracker()
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["historical"], uncertain: false), "startup completed history never forms a task batch")
        expect(!tracker.consume(tasks: [task("codex"), task("cindy", "cindy")], completedTaskIDs: [], uncertain: false), "concurrent running batch does not finish")
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["codex"], uncertain: false), "Codex success plus unconfirmed Cindy disappearance cannot auto-sleep")
        expect(!tracker.consume(tasks: [task("a"), task("b")], completedTaskIDs: [], uncertain: false), "new batch begins after failed batch clears")
        expect(!tracker.consume(tasks: [task("b")], completedTaskIDs: ["a"], uncertain: false), "first completion accumulates across polls")
        expect(tracker.consume(tasks: [], completedTaskIDs: ["b"], uncertain: false), "all task normal terminals across polls complete batch")
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["b"], uncertain: false), "completion fires once")
        _ = tracker.consume(tasks: [task("a"), task("cindy", "cindy")], completedTaskIDs: [], uncertain: false)
        _ = tracker.consume(tasks: [task("cindy", "cindy")], completedTaskIDs: ["a"], uncertain: false)
        expect(!tracker.consume(tasks: [], completedTaskIDs: [], uncertain: false), "later Cindy unknown exit cannot reuse earlier Codex normal terminal")
        _ = tracker.consume(tasks: [task("a")], completedTaskIDs: [], uncertain: false)
        _ = tracker.consume(tasks: [task("a")], completedTaskIDs: [], uncertain: true)
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["a"], uncertain: false), "unknown intermediate poll contaminates running batch")
        _ = tracker.consume(tasks: [task("a")], completedTaskIDs: [], uncertain: false)
        tracker.reset()
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["a"], uncertain: false), "settings reset prevents old completion from triggering")
        _ = tracker.consume(tasks: [task("selected")], completedTaskIDs: [], uncertain: false)
        expect(tracker.consume(tasks: [], completedTaskIDs: ["selected", "unselected"], uncertain: false), "unselected normal terminal does not interfere with selected batch")
        _ = tracker.consume(tasks: [task("long")], completedTaskIDs: [], uncertain: false)
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["long"], uncertain: false, interrupted: true), "short concurrent abort blocks a successful observed task from auto-sleeping")
        _ = tracker.consume(tasks: [task("long")], completedTaskIDs: [], uncertain: false)
        _ = tracker.consume(tasks: [task("long")], completedTaskIDs: [], uncertain: false, interrupted: true)
        expect(!tracker.consume(tasks: [], completedTaskIDs: ["long"], uncertain: false), "interruption contaminates a running batch across polls")
        _ = tracker.consume(tasks: [], completedTaskIDs: [], uncertain: false, interrupted: true)
        _ = tracker.consume(tasks: [task("fresh")], completedTaskIDs: [], uncertain: false)
        expect(tracker.consume(tasks: [], completedTaskIDs: ["fresh"], uncertain: false), "standalone old interruption does not poison a later clean batch")
        let sourceInterruption = AgentSnapshot(interruptedSources: ["cindy"])
        expect(sourceInterruption.hasInterruption(selectedAgentIDs: ["cindy"]), "selected interruption is delivered")
        expect(!sourceInterruption.hasInterruption(selectedAgentIDs: ["codex"]), "unselected interruption does not cancel a selected batch")
        expect(AgentSnapshot(interruptedSources: ["*"]).hasInterruption(selectedAgentIDs: []), "untagged generic interruption remains active with every named App deselected")
        let nativeUnknown = AgentSnapshot(uncertain: true, uncertainSources: ["cindy"])
        expect(nativeUnknown.hasUncertainty(selectedAgentIDs: ["cindy"]), "native unknown protects even when Codex is not selected")
        expect(!nativeUnknown.hasUncertainty(selectedAgentIDs: ["codex"]), "unselected source uncertainty does not hold selected Agent awake")
        let genericUnknown = AgentSnapshot(uncertain: true, uncertainSources: ["*"])
        expect(genericUnknown.hasUncertainty(selectedAgentIDs: ["claude"]), "unknown generic lease source protects selected Agents")
        expect(genericUnknown.hasUncertainty(selectedAgentIDs: []), "generic untagged lease remains protected even when named Apps are deselected")
        let legacyUnknown = AgentSnapshot(uncertain: true)
        expect(legacyUnknown.hasUncertainty(selectedAgentIDs: ["workbuddy"]), "unknown legacy source stays conservative")
        print("PASS: \(checks) AgentCompletion checks")
    }
}
