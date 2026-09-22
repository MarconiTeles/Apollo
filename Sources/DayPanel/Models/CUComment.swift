import Foundation

/// One ClickUp task comment as exposed by `/task/{id}/comment`.
struct CUComment: Identifiable, Equatable, Hashable {
    let id:           String
    let text:         String
    let date:         Date
    let userId:       Int?
    let userName:     String?
    let userEmail:    String?
    let userColor:    String?           // hex of the user's avatar tint
    let initials:     String?
    let profilePic:   String?           // optional URL string
    var resolved:     Bool
    var reactions:    [Reaction]
    let replyCount:   Int
    /// Files attached to this comment (drag-and-drop into the
    /// comment box, paperclip-attach, or pasted media). ClickUp
    /// returns these as a separate `attachments` array on each
    /// comment object — they're NOT inlined into `comment_text`,
    /// so the previous URL-detection-only rendering missed them.
    let attachments:  [CUTask.Attachment]

    /// Raw `attachment_id`s referenced by this comment's segments. ClickUp
    /// sometimes returns an attachment segment carrying only the id (no url,
    /// `attachment: null`), which can't become a full `CUTask.Attachment` —
    /// but the id alone is enough for the media-transfer verification that
    /// decides whether a published comment really carries its file.
    var attachmentIds: [String] = []

    /// Action-item metadata returned by ClickUp for assigned comments.
    /// Kept on the canonical comment model so every surface can resolve,
    /// reassign and distinguish "Atribuídas a mim" from "Delegados por mim"
    /// without reparsing raw dictionaries in the view layer.
    var assignee:      Participant? = nil
    var assignedBy:    Participant? = nil

    struct Participant: Identifiable, Equatable, Hashable {
        let id: Int
        let username: String
        let email: String?
        let color: String?
        let initials: String?
        let profilePicture: String?
    }

    struct Reaction: Equatable, Hashable {
        let emoji:    String   // "👍", "❤️", etc.
        let userIds:  [Int]    // who reacted with this emoji
    }
}
