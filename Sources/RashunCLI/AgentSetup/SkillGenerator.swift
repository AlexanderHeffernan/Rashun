import Foundation
import RashunCore

enum SkillGenerator {
    static let startMarker = "<!-- rashun:start -->"
    static let endMarker = "<!-- rashun:end -->"

    static func generate(for source: AISource) -> String {
        let agentName = source.agentName
        let sourceCLIName = source.name.lowercased()

        return """
        \(startMarker)
        ## Rashun — AI Usage Monitoring

        You are \(agentName), which uses the "\(source.name)" quota. This project has
        Rashun installed — a CLI tool that tracks your remaining AI usage quota.

        ### When to check usage
        - **Always** before starting a large or multi-step task (even if the user doesn’t mention Rashun)
        - Immediately if the user asks whether you have enough usage to complete a task
        - When you sense you've been working for a while and may have used significant quota
        - After completing a major task, to inform the user of remaining capacity

        ### How to check usage
        1. Run `rashun status \(sourceCLIName) --json` to see your current remaining percentage.
        2. Run `rashun forecast \(sourceCLIName) --json` and read the "summary" field to understand
           whether you are projected to run out before your quota resets.

        ### How to interpret the data
        Do NOT use a fixed percentage as a threshold. A source with 20% remaining on a monthly
        quota is very different from 20% remaining on a daily quota. Use the forecast summary
        to reason about whether you have enough remaining usage to complete the current task.

        The forecast summary will tell you one of:
        - When the source will reach 100% (regenerating sources like Amp)
        - When the source will hit 0% and when it resets (depleting sources like Copilot)
        - How much will remain at reset (assuming current usage rate is sustained)

        ### When to warn the user
        If the forecast indicates you will run out before the quota resets, or if the remaining
        usage looks insufficient for the task at hand:
        1. Stop and inform the user of the situation.
        2. Offer to save a summary of the current conversation as a markdown file.
        3. Run `rashun status --json` (all sources) and show the user which other sources
           have remaining capacity, so they can choose which agent to switch to.
        \(endMarker)
        """
    }
}
