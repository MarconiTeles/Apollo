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
    let resolved:     Bool
    let reactions:    [Reaction]
    let replyCount:   Int
    /// Files attached to this comment (drag-and-drop into the
    /// comment box, paperclip-attach, or pasted media). ClickUp
    /// returns these as a separate `attachments` array on each
    /// comment object — they're NOT inlined into `comment_text`,
    /// so the previous URL-detection-only rendering missed them.
    let attachments:  [CUTask.Attachment]

    struct Reaction: Equatable, Hashable {
        let emoji:    String   // "👍", "❤️", etc.
        let userIds:  [Int]    // who reacted with this emoji
    }
}
