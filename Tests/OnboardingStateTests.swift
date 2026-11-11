import Foundation

@main struct OnboardingStateTests {
    static func main() {
        let suite = "local.webby.onboarding-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        var draft = WebbyOnboardingDraft(spaces: [.init(id: id, name: "Personal")], selectedSpace: id)
        precondition(WebbyOnboardingDraft.shouldPresent(existingProfiles: false, saved: nil))
        precondition(!WebbyOnboardingDraft.shouldPresent(existingProfiles: true, saved: nil))
        draft.back()
        precondition(draft.step == .welcome)
        for step in WebbyOnboardingStep.allCases.dropFirst() {
            draft.advance()
            precondition(draft.step == step)
        }
        draft.advance()
        precondition(draft.step == .ready)
        draft.back()
        draft.theme = "ghost"
        draft.widgets = ["calculator", "note"]
        draft.search = "brave"
        draft.importIDs["Profile 1"] = UUID()
        draft.importInterrupted = true
        draft.save(to: defaults)
        let resumed = WebbyOnboardingDraft.load(from: defaults)!
        precondition(resumed.step == .links && resumed.theme == "ghost" && resumed.widgets == draft.widgets)
        precondition(resumed.search == "brave" && resumed.importIDs == draft.importIDs && resumed.importInterrupted)
        precondition(WebbyOnboardingDraft.shouldPresent(existingProfiles: true, saved: resumed))
        for terminalPhase in [WebbyOnboardingDraft.Phase.skipped, .completed] {
            draft.phase = terminalPhase
            draft.save(to: defaults)
            precondition(!WebbyOnboardingDraft.shouldPresent(existingProfiles: true, saved: .load(from: defaults)))
        }
        draft.version = 99
        draft.save(to: defaults)
        precondition(WebbyOnboardingDraft.load(from: defaults) == nil)
        print("PASS: first-run gating, ten steps, Back, interruption recovery, skip, completion and schema version")
    }
}
