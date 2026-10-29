import Foundation

/// Now and then, at a happy moment, opens the share panel with a friendly "Enjoying DiskGarden?" header.
///
/// Happy moments: the 2nd and 5th launch and every 5th after that; total freed space passing 10 / 50 / 100 / 250 /
/// 500 GB. The congratulations card has its own Share button and counts as a nudge.
/// Limits: never on the first launch, at most once every `minDays` (Remote Config, default 2) and 6 times per round;
/// after `resetDays` (default 10) without a nudge a new round starts (the count resets). Deferred while a scan runs,
/// never over another prompt, and never again after the user shared or turned it off in Settings. Remote Config can switch it off entirely.
@MainActor @Observable
final class ShareNudge {
    static let shared = ShareNudge()

    /// Set when the panel should open as a nudge (the toolbar share button presents it and clears it).
    var pending: ShareContent?
    /// Bumped to make the toolbar share button expand and shake (launch, after a deletion).
    private(set) var attention = 0
    /// How many times the icon shakes for the latest `attention` (more after a deletion).
    private(set) var attentionShakes = 2

    /// Settings → "Suggest sharing DiskGarden now and then".
    var isEnabled: Bool {
        get { !defaults.bool(forKey: Keys.optedOut) }
        set { defaults.set(!newValue, forKey: Keys.optedOut); enabledVersion += 1 }
    }
    private var enabledVersion = 0 // makes `isEnabled` observable

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let launches = "shareNudge.launches"
        static let lastShown = "shareNudge.lastShown"
        static let shownCount = "shareNudge.shownCount"
        static let optedOut = "shareNudge.optedOut"
        static let shared = "shareNudge.shared"
        static let milestone = "shareNudge.lastMilestoneGB"
    }
    private static let maxShown = 6
    private static let milestonesGB: [UInt64] = [10, 50, 100, 250, 500]

    // MARK: Events

    func appDidLaunch() {
        let launches = defaults.integer(forKey: Keys.launches) + 1
        defaults.set(launches, forKey: Keys.launches)
        let forced = ProcessInfo.processInfo.environment["DG_SHARE_NUDGE"] != nil // debug: nudge on this launch
        if forced || launches == 2 || launches % 5 == 0, request(.app, after: 4) { return }
        bumpAttention(after: 1.5)
    }

    /// After a deletion: `total` is the lifetime freed space; `showedCard` when the congratulations card appeared.
    func didFreeSpace(total: UInt64, showedCard: Bool) {
        if showedCard { markShown() } // the card offers Share itself
        defer { bumpAttention(after: 0.6, shakes: 5) }
        let reached = Self.milestonesGB.last { total >= $0 * 1_000_000_000 } ?? 0
        guard reached > UInt64(defaults.integer(forKey: Keys.milestone)) else { return }
        defaults.set(Int(reached), forKey: Keys.milestone)
        if !showedCard { request(.milestone(total), after: 1.5) }
    }

    /// The user shared from any share panel: never nudge again.
    func didShare() { defaults.set(true, forKey: Keys.shared) }

    // MARK: Policy

    private var isEligible: Bool {
        startNewRoundIfQuiet()
        guard isEnabled, RemoteSettings.shared.bool(.shareSuggestionsEnabled),
              !defaults.bool(forKey: Keys.shared),
              defaults.integer(forKey: Keys.launches) >= 2,
              defaults.integer(forKey: Keys.shownCount) < Self.maxShown else { return false }
        if let last = defaults.object(forKey: Keys.lastShown) as? Date {
            let minDays = max(1, RemoteSettings.shared.number(.shareSuggestionMinDays))
            return Date().timeIntervalSince(last) >= minDays * 86_400
        }
        return true
    }

    func bumpAttention(after delay: TimeInterval, shakes: Int = 2) {
        guard RemoteSettings.shared.bool(.shareSuggestionsEnabled) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            attentionShakes = shakes
            attention += 1
        }
    }

    /// Returns whether the panel is on its way (eligible now; it may still be dropped at the moment of showing).
    @discardableResult
    private func request(_ content: ShareContent, after delay: TimeInterval) -> Bool {
        let forced = ProcessInfo.processInfo.environment["DG_SHARE_NUDGE"] != nil // debug: skip the frequency policy
        guard forced || isEligible else { return false }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            let app = AppModel.shared
            // A running scan defers the nudge until it finishes (the panel would cover the progress).
            while app.isScanningAnything { try? await Task.sleep(for: .seconds(1)) }
            // Not over another prompt (the congratulations card offers Share itself).
            guard forced || isEligible, pending == nil, app.congratulations == nil else { return }
            pending = content
            if !forced { markShown() }
        }
        return true
    }

    /// No nudge for `resetDays`: start counting from zero again (spacing and the per-round cap apply anew).
    private func startNewRoundIfQuiet() {
        guard let last = defaults.object(forKey: Keys.lastShown) as? Date else { return }
        let resetDays = max(1, RemoteSettings.shared.number(.shareSuggestionResetDays))
        if Date().timeIntervalSince(last) >= resetDays * 86_400 {
            defaults.set(0, forKey: Keys.shownCount)
        }
    }

    private func markShown() {
        defaults.set(Date(), forKey: Keys.lastShown)
        defaults.set(defaults.integer(forKey: Keys.shownCount) + 1, forKey: Keys.shownCount)
    }
}
