import Foundation

/// Client for the single live review link's backend (a Cloudflare Worker over
/// KV). Mirrors the web's `src/contract/session.ts`: a review is ONE JSON blob
/// per attachment, keyed by `att`. The native Apollo review opens/creates and
/// modifies the SAME blob as the web — so both are the same review behind the
/// same `?att=` link.
///
/// Type-agnostic on purpose: ReviewKit's `ReviewComment` is internal to that
/// module, so we pass JSON through (the worker + ReviewKit own the shape) and
/// never decode comments here.
enum ReviewBackend {
    /// Same Worker the web talks to. Endpoints are public (no auth, CORS open).
    static let base = "https://apollo-review-proxy.marconimpn.workers.dev"

    /// The review's stable identity (== the KV key, == the web link's `att`).
    /// Derived from the media URL so the native open and the web REVISAR link
    /// converge on the same blob. Mirrors `AppState.stableId`.
    static func att(forMediaUrl url: String) -> String { AppState.stableId(url) }

    /// Cheap badge poll: does a review exist for this media, and when did it
    /// last change? No comments/markup downloaded.
    struct Meta { let exists: Bool; let updatedAt: String? }
    static func meta(forMediaUrl mediaUrl: String) async -> Meta? {
        let body: [String: Any] = ["attachmentId": att(forMediaUrl: mediaUrl)]
        guard let data = await post("/session/meta", body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Meta(exists: (obj["exists"] as? Bool) ?? false,
                    updatedAt: obj["updatedAt"] as? String)
    }

    /// Load-or-create the review for a media URL; returns the worker's
    /// `{reviewId, versionId, status, comments}` JSON for ReviewKit to merge.
    static func resolve(mediaUrl: String, ext: String, title: String,
                        taskId: String, listId: String?, uploaderId: Int?) async -> Data? {
        var body: [String: Any] = [
            "attachmentId": att(forMediaUrl: mediaUrl),
            "taskId": taskId,
            "mediaUrl": mediaUrl,
            "mediaTitle": title,
            "mediaKind": mediaKind(forExt: ext),
        ]
        if let listId { body["listId"] = listId }
        if let uploaderId {
            body["uploaderId"] = uploaderId
            body["createdById"] = uploaderId   // the uploader owns/created it
        }
        return await post("/session/resolve", body)
    }

    /// Persist the full review (debounced by the caller). `payloadData` is the
    /// ReviewPayload JSON ReviewKit produces; we lift `status`/`comments` out of
    /// it and key the blob by `att` derived from its `mediaUrl`.
    @discardableResult
    static func save(payloadData: Data) async -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let mediaUrl = obj["mediaUrl"] as? String, !mediaUrl.isEmpty
        else { return false }
        let body: [String: Any] = [
            "reviewId": att(forMediaUrl: mediaUrl),
            "versionId": "v1",
            "status": obj["status"] ?? "in_review",
            "comments": obj["comments"] ?? [],
        ]
        return await post("/session/save", body) != nil
    }

    // ── "Last seen" per review (drives the REVIEW button badge) ──────────────
    // Local-only state: the `updatedAt` this user last saw for each review.
    // A review whose remote `updatedAt` is newer than this got changed by
    // someone else → badge. Opening the review marks it seen.
    static func lastSeen(forMediaUrl mediaUrl: String) -> String? {
        UserDefaults.standard.string(forKey: "reviewSeen.\(att(forMediaUrl: mediaUrl))")
    }
    static func markSeen(forMediaUrl mediaUrl: String, updatedAt: String?) {
        guard let u = updatedAt else { return }
        UserDefaults.standard.set(u, forKey: "reviewSeen.\(att(forMediaUrl: mediaUrl))")
    }
    /// True when there's a change the user hasn't seen yet. Conservative: never
    /// badges a review the user has never opened (lastSeen == nil), so the dot
    /// only ever means "updated since you last looked".
    static func hasUnseenUpdate(meta: Meta, mediaUrl: String) -> Bool {
        guard meta.exists, let remote = meta.updatedAt, let seen = lastSeen(forMediaUrl: mediaUrl)
        else { return false }
        return remote > seen
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    private static func mediaKind(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": return "video"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff": return "image"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "audio"
        default: return "document"
        }
    }

    @discardableResult
    private static func post(_ path: String, _ body: [String: Any]) async -> Data? {
        guard let url = URL(string: base + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode < 300 else { return nil }
        return respData
    }
}
