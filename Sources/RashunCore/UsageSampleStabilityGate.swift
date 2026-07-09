import Foundation

/// Holds suspicious near-full quota jumps until a consecutive refresh confirms them.
/// Keeping this at ingestion ensures every consumer sees the same stable usage data.
public struct UsageSampleStabilityGate {
    public struct VerifiedUsage: Sendable {
        public let usage: UsageResult
        public let previousAccepted: UsageResult
        public let wasConfirmed: Bool
        /// The original near-full sample that established a confirmed reset.
        /// Consumers should continue displaying `usage`, but may use this as
        /// reset evidence if normal usage occurred before the confirmation poll.
        public let confirmedResetUsage: UsageResult?

        public init(
            usage: UsageResult,
            previousAccepted: UsageResult,
            wasConfirmed: Bool,
            confirmedResetUsage: UsageResult? = nil
        ) {
            self.usage = usage
            self.previousAccepted = previousAccepted
            self.wasConfirmed = wasConfirmed
            self.confirmedResetUsage = confirmedResetUsage
        }
    }

    private struct Candidate {
        let usage: UsageResult
        let previousAccepted: UsageResult
    }

    private var candidates: [String: Candidate] = [:]

    public init() {}

    /// Returns `nil` when the incoming sample is awaiting a confirming refresh.
    public mutating func verifiedUsage(
        scope: String,
        incoming: UsageResult,
        previousAccepted: UsageResult?
    ) -> VerifiedUsage? {
        guard let previousAccepted else {
            candidates.removeValue(forKey: scope)
            return VerifiedUsage(usage: incoming, previousAccepted: incoming, wasConfirmed: false)
        }

        if let candidate = candidates[scope] {
            if confirms(candidate: candidate, with: incoming) {
                candidates.removeValue(forKey: scope)
                return VerifiedUsage(
                    usage: incoming,
                    previousAccepted: candidate.previousAccepted,
                    wasConfirmed: true,
                    confirmedResetUsage: candidate.usage
                )
            }
            candidates.removeValue(forKey: scope)
        }

        guard isPotentialQuotaJump(from: previousAccepted, to: incoming) else {
            return VerifiedUsage(usage: incoming, previousAccepted: previousAccepted, wasConfirmed: false)
        }

        candidates[scope] = Candidate(usage: incoming, previousAccepted: previousAccepted)
        return nil
    }

    private func isPotentialQuotaJump(from previous: UsageResult, to current: UsageResult) -> Bool {
        guard current.percentRemaining >= 85,
              current.percentRemaining - previous.percentRemaining >= 20 else {
            return false
        }

        if let previousReset = previous.resetDate, let currentReset = current.resetDate {
            return currentReset > previousReset
        }
        return previous.percentRemaining < 95
    }

    private func confirms(candidate: Candidate, with current: UsageResult) -> Bool {
        switch (candidate.usage.resetDate, current.resetDate) {
        case let (candidateReset?, currentReset?):
            // Providers occasionally round or slightly revise the reset time.
            // Require the quota itself to remain near full too. A reset date
            // alone has proven insufficient evidence when an API glitches.
            return abs(currentReset.timeIntervalSince(candidateReset)) <= 60 &&
                current.percentRemaining >= 90 &&
                abs(current.percentRemaining - candidate.usage.percentRemaining) <= 10
        case (nil, nil):
            // Without a reset date, require another clearly near-full sample
            // while allowing a modest amount of real post-reset usage.
            return current.percentRemaining >= 90 &&
                abs(current.percentRemaining - candidate.usage.percentRemaining) <= 10
        default:
            return false
        }
    }

}
