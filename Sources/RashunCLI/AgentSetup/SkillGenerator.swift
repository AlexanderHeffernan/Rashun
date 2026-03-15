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

        ### Routine usage check (do this quietly)
        **At the start of every thread**, before doing any other work, silently run:
        ```
        rashun forecast \(sourceCLIName) --json
        rashun status \(sourceCLIName) --json
        ```
        Read the `summary` field from the forecast to see whether you are on track
        to run out before your quota resets, and the status to see your current
        remaining percentage.

        - **If usage looks healthy** — proceed with the task. Do NOT mention
          Rashun or the check to the user; just get to work.
        - **If the forecast warns you will run out, or remaining usage is very
          low** — stop and tell the user before doing any work (see "When to
          warn the user" below).

        Also re-check during longer sessions: after completing a major piece of work,
        or when the user starts a new piece of work within the same thread.

        ### On-demand usage check
        If the user asks about usage or remaining capacity, run both commands
        above and present the user with a complete picture of their current
        usage and forecast.

        ### How to interpret the data
        Do NOT use a fixed percentage as a threshold. A source with 20% remaining
        on a monthly quota is very different from 20% on a daily quota. Always rely
        on the forecast summary — it accounts for reset timing and usage rate.

        The forecast summary will tell you one of:
        - When the source will reach 100% (regenerating sources like Amp)
        - When the source will hit 0% and when it resets (depleting sources Copilot)
        - How much will remain at reset (assuming the current usage rate continues)

        ### When to warn the user
        If the forecast indicates you will run out before the quota resets, or if
        remaining usage looks insufficient for the task at hand:
        1. Stop and inform the user before starting further work.
        2. Offer to save a summary of the current conversation as a markdown file.
        3. Run `rashun status --json` (all sources) and show the user which other
           sources have remaining capacity, so they can switch agents.
        \(endMarker)
        """
    }
}
