import AppKit
import ReviewKit

/// Bridges Apollo → the review engine. `params(...)` builds OpenReviewParams for
/// the EMBEDDED workflow (ReviewKit sheet in-app); `deepLink/open` target the
/// standalone app via the apolloreview:// URL scheme.
enum ReviewLink {
    static let scheme = "apolloreview"

    /// Media types the review app can open (video / image / document).
    static func isReviewable(_ ext: String) -> Bool {
        [
            "mp4", "mov", "avi", "mkv", "webm", "m4v",                 // video
            "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", // image
            "pdf",                                                      // document
        ].contains(ext.lowercased())
    }

    /// Params for the embedded ReviewKit sheet.
    static func params(attachment: CUTask.Attachment,
                       taskId: String,
                       listId: String?,
                       uploaderId: Int?,
                       actorId: Int,
                       actorName: String,
                       reviewId: String? = nil,
                       versionId: String? = nil,
                       commentId: String? = nil) -> OpenReviewParams {
        OpenReviewParams(
            taskId: taskId,
            listId: listId,
            attachmentId: attachment.id,
            mediaUrl: attachment.url,
            mediaTitle: attachment.title,
            ext: attachment.ext,
            uploaderId: uploaderId,
            actorId: actorId,
            actorName: actorName,
            reviewId: reviewId,
            versionId: resolvedVersionId(metadataVersionId: versionId,
                                         mediaTitle: attachment.title),
            commentId: commentId
        )
    }

    /// Older malformed review metadata can claim `v1` while the physical file
    /// is explicitly named `... V4.mov`. The final version marker in the media
    /// title is the authoritative revision in that case; a valid newer server
    /// value remains the fallback for titles without a marker.
    static func resolvedVersionId(metadataVersionId: String?,
                                  mediaTitle: String) -> String? {
        let title = mediaTitle as NSString
        let range = NSRange(location: 0, length: title.length)
        let pattern = #"(?i)(?:^|[\s._·-])v(\d+)(?=\s*(?:[._·-]|$))"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.matches(in: mediaTitle, range: range).last,
           match.numberOfRanges > 1 {
            let digits = title.substring(with: match.range(at: 1))
            if let number = Int(digits), number > 0 { return "v\(number)" }
        }

        let normalized = metadataVersionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, normalized.range(of: #"^v\d+$"#,
                                                options: .regularExpression) != nil
        else { return nil }
        return normalized
    }

    static func deepLink(attachment: CUTask.Attachment,
                         taskId: String,
                         listId: String?,
                         uploaderId: Int?,
                         actorId: Int,
                         actorName: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "open"
        var items: [URLQueryItem] = [
            .init(name: "taskId", value: taskId),
            .init(name: "attachmentId", value: attachment.id),
            .init(name: "mediaUrl", value: attachment.url),
            .init(name: "mediaTitle", value: attachment.title),
            .init(name: "ext", value: attachment.ext),
            .init(name: "actorId", value: String(actorId)),
            .init(name: "actorName", value: actorName),
        ]
        if let listId { items.append(.init(name: "listId", value: listId)) }
        if let uploaderId { items.append(.init(name: "uploaderId", value: String(uploaderId))) }
        c.queryItems = items
        return c.url
    }

    /// Opens the review app for an attachment. Returns false if the app isn't
    /// installed / the URL can't be built (caller can fall back to web later).
    @discardableResult
    static func open(attachment: CUTask.Attachment,
                     taskId: String,
                     listId: String?,
                     uploaderId: Int?,
                     actorId: Int,
                     actorName: String) -> Bool {
        guard let url = deepLink(attachment: attachment, taskId: taskId, listId: listId,
                                 uploaderId: uploaderId, actorId: actorId, actorName: actorName)
        else { return false }
        return NSWorkspace.shared.open(url)
    }
}
