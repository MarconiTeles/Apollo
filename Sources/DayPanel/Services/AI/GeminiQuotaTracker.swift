import Foundation
import Combine

/// Tracks per-model daily-quota exhaustion across the Gemini free
/// tier so the provider's cascade doesn't keep banging on a model
/// it already burned today. State is keyed by *Pacific calendar
/// day* (Google resets free-tier quotas at midnight America/Los_Angeles)
/// and persists in `UserDefaults` so a restart at 11pm doesn't
/// magically un-exhaust models.
///
/// The chat header observes `activeModel` / `preferredModel` to
/// surface a small "currently degraded to X" badge when the user's
/// preferred model has been swapped out for a lower-quality fallback.
final class GeminiQuotaTracker: ObservableObject {

    static let shared = GeminiQuotaTracker()

    private static let exhaustedKey = "dp_gemini_exhausted_v1"
    private static let dayKey       = "dp_gemini_exhausted_day"

    /// Set of model IDs that have hit their daily quota today.
    /// Read by GeminiProvider before each request to skip dead
    /// models, and by the chat header to render the badge.
    @Published private(set) var exhaustedModels: Set<String> = []

    /// Per-model "throttled until" timestamps for *per-minute*
    /// rate-limit hits. Unlike daily exhaustion these are
    /// in-memory only — the windows reset in seconds, not at
    /// midnight, so persisting them across restarts buys nothing.
    /// The chain skips any model whose throttle window hasn't
    /// expired yet, and the badge surfaces the same orange
    /// indicator as the daily-quota path so the user knows the
    /// active model is a downgrade.
    @Published private(set) var throttledUntil: [String: Date] = [:]

    /// The model that actually answered the most recent request
    /// (nil before the first call). Drives the header badge —
    /// when this differs from `preferredModel`, the user sees a
    /// "degraded" indicator.
    @Published private(set) var activeModel: String? = nil

    /// The model the user *wants* to use (whatever was passed to
    /// the GeminiProvider init, before cascade). Used as the
    /// reference point for "is the active model degraded?".
    @Published private(set) var preferredModel: String? = nil

    init() {
        let storedDay = UserDefaults.standard.string(forKey: Self.dayKey) ?? ""
        let today = Self.currentPacificDay()
        if storedDay == today,
           let arr = UserDefaults.standard.stringArray(forKey: Self.exhaustedKey) {
            self.exhaustedModels = Set(arr)
        } else {
            // Stale day → start clean and stamp today's date so
            // the next mark-exhausted persists with the right day.
            self.exhaustedModels = []
            UserDefaults.standard.set(today, forKey: Self.dayKey)
            UserDefaults.standard.set([String](),
                                      forKey: Self.exhaustedKey)
        }
    }

    /// True iff `model` was marked exhausted earlier *today* in
    /// Pacific time. Resets the in-memory state if the calendar
    /// has flipped over since the last check, so a request just
    /// after midnight PT correctly sees a clean slate without
    /// needing an app restart.
    func isExhausted(_ model: String) -> Bool {
        rolloverIfNeeded()
        return exhaustedModels.contains(model)
    }

    /// True iff `model` is either daily-exhausted OR currently
    /// inside an in-flight per-minute throttle window. Used by
    /// the GeminiProvider chain to skip models we know would
    /// just bounce a 429 back at us.
    func isUnavailable(_ model: String) -> Bool {
        if isExhausted(model) { return true }
        if let until = throttledUntil[model], until > Date() { return true }
        return false
    }

    /// Mark `model` as rate-limited for `seconds` from now. Used
    /// when Gemini returns a 429 with a `retry in Ns` hint that's
    /// too long to wait inline (e.g. 58s would freeze the chat).
    /// The chain falls through to the next model in the cascade
    /// instead of waiting, and re-becomes eligible automatically
    /// once the timestamp expires.
    func markThrottled(_ model: String, forSeconds seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only extend, never shrink — overlapping hints
            // shouldn't accidentally release the model early.
            if let existing = self.throttledUntil[model], existing > until { return }
            self.throttledUntil[model] = until
        }
    }

    /// True iff `model` is currently in its per-minute throttle
    /// window (NOT a daily exhaustion). Lets the badge label
    /// distinguish the two cases for the user.
    func isThrottled(_ model: String) -> Bool {
        guard let until = throttledUntil[model] else { return false }
        return until > Date()
    }

    /// Mark `model` as out-of-quota for the rest of the Pacific
    /// day. Idempotent — calling repeatedly is safe.
    func markExhausted(_ model: String) {
        rolloverIfNeeded()
        guard !exhaustedModels.contains(model) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var set = self.exhaustedModels
            set.insert(model)
            self.exhaustedModels = set
            UserDefaults.standard.set(Array(set), forKey: Self.exhaustedKey)
        }
    }

    /// Record the model that just produced a successful response.
    /// `preferred` is the user's first-choice model — passing it
    /// lets the header badge know whether the active model is the
    /// preferred one or a degraded fallback.
    func setActive(_ model: String, preferred: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.preferredModel != preferred { self.preferredModel = preferred }
            if self.activeModel    != model     { self.activeModel    = model }
        }
    }

    /// Reset in-memory exhaustion if the Pacific calendar day has
    /// changed since the on-disk timestamp. Called on every read
    /// so we don't need a timer.
    private func rolloverIfNeeded() {
        let today = Self.currentPacificDay()
        let storedDay = UserDefaults.standard.string(forKey: Self.dayKey) ?? ""
        if storedDay != today {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exhaustedModels = []
                UserDefaults.standard.set(today, forKey: Self.dayKey)
                UserDefaults.standard.set([String](),
                                          forKey: Self.exhaustedKey)
            }
        }
    }

    private static func currentPacificDay() -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// Friendly model labels for the header badge. Falls back to
    /// the raw id if not in the table — keeps the badge readable
    /// even when Google ships a new model we haven't catalogued.
    static func displayLabel(for modelId: String) -> String {
        switch modelId {
        case "gemini-2.5-pro":     return "Gemini 2.5 Pro"
        case "gemini-2.5-flash":   return "Gemini 2.5 Flash"
        case "gemini-2.0-flash":   return "Gemini 2.0 Flash"
        case "gemini-flash-latest":return "Gemini Flash (latest)"
        default:                   return modelId
        }
    }
}
