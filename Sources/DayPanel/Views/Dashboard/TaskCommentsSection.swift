import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Comments thread for a single ClickUp task. Modeled after ClickUp's
// in-app comments panel:
//   - Avatar + name + timestamp + body
//   - File attachments (any type) via paperclip in composer
//   - Emoji reactions (👍 ❤️ 😂 🎉 …) per comment
//   - Threaded replies via /comment/{id}/reply
//   - @-mention autocomplete from workspace members
//
// All API state mutates through AppState → ClickUpService.

struct TaskCommentsSection: View, Equatable {
    let task: CUTask
    /// AppState held as a plain reference, NOT `@EnvironmentObject`.
    /// Same reasoning as `TaskDetailSheet.appState` — subscribing
    /// here meant every unrelated `@Published` mutation in
    /// AppState (sync ticks, attachmentHydration, etc.)
    /// invalidated the comments column's body, including the
    /// composer, the comment list ForEach, and every reaction
    /// pill — easily costing tens of milliseconds per re-render
    /// and producing the visible flicker reported by the user.
    let appState: AppState
    /// When true, a `Spacer` is inserted between the comment list and
    /// the composer so the composer sticks to the BOTTOM of whatever
    /// parent height it's given. Used by the popup version of the
    /// task detail (`TaskDetailSheet`) where the comments column gets
    /// the full popover height.
    var composerAtBottom: Bool = false

    /// Equatable conformance — `.equatable()` short-circuits
    /// re-renders when surrounding views re-evaluate but
    /// neither the task nor the layout knob changed. The local
    /// comment list / drafts / focus state live in `@State` and
    /// drive their own redraws independently.
    static func == (lhs: TaskCommentsSection, rhs: TaskCommentsSection) -> Bool {
        lhs.task == rhs.task && lhs.composerAtBottom == rhs.composerAtBottom
    }

    @State private var comments:        [CUComment] = []
    /// Typed activity events (status changes, file uploads,
    /// assignee adds, etc.) interleaved with comments to form
    /// the unified timeline. Loaded in parallel with comments
    /// in `refresh()` and merged via the `timeline` computed
    /// property below. Empty array on workspaces where the
    /// `/task/{id}/history` endpoint returns nothing — the
    /// timeline degrades cleanly to comments-only.
    @State private var events:          [TaskActivityEvent] = []
    @State private var draft            = ""
    @State private var loading          = false
    @State private var posting          = false
    @State private var uploading        = false
    @State private var uploadProgress:  Double      = 0
    @State private var uploadFilename:  String?     = nil
    @State private var uploadIndex:     Int         = 0
    @State private var uploadTotal:     Int         = 0
    @FocusState private var draftFocused: Bool

    // Per-comment ephemeral UI state
    @State private var expandedReplies: Set<String> = []
    @State private var repliesByParent: [String: [CUComment]] = [:]
    @State private var replyDrafts:     [String: String]      = [:]
    @State private var emojiPickerFor:  String?
    @State private var mentionQuery:    String?           // nil = inactive
    /// Member IDs the user has selected from the mention
    /// picker for the current draft. Tracked here so the
    /// send path can pass them to ClickUp's API and trigger
    /// real notifications — without this list the API
    /// receives only the literal "@username" string and
    /// can't tell which workspace member to ping.
    @State private var mentionedIds:    [Int] = []

    /// Files dragged or picked into the composer that haven't been
    /// sent yet — they render as chips above the textfield and
    /// flush to ClickUp when the user clicks "Enviar", attached to
    /// the comment we just posted (so text + files end up in ONE
    /// bubble in the timeline). Drag-and-drop and the paperclip
    /// button both feed this queue.
    @State private var pendingAttachments: [URL] = []

    /// True while a Finder drag is hovering anywhere over the
    /// composer surface. Drives the accent ring overlay so the
    /// user knows the drop will be accepted.
    @State private var isDropTargeted: Bool = false

    private let quickEmojis = ["👍", "❤️", "😂", "🎉", "🚀", "👀", "🙏"]

    // MARK: - Unified timeline merge
    //
    // Comments and activity events are sourced from two
    // different ClickUp endpoints (`/comment` + `/history`),
    // but the user sees ONE chronological thread. We merge by
    // date here at render time rather than persisting a
    // pre-merged stream — both inputs already live in `@State`,
    // so SwiftUI invalidates this property whenever either
    // changes, and the merge is O(n+m) on collections that
    // realistically max out at ~200 entries per task.

    /// One row in the unified timeline. Either a full comment
    /// (with body / reactions / replies) or a compact activity
    /// event (status change, upload, assignee, …). `id` is
    /// prefixed to keep `ForEach` happy when a comment id and
    /// an event id collide (rare, but ClickUp's id namespaces
    /// aren't guaranteed disjoint).
    private enum TimelineEntry: Identifiable {
        case comment(CUComment)
        case event(TaskActivityEvent)

        var id: String {
            switch self {
            case .comment(let c): return "c:" + c.id
            case .event(let e):   return "e:" + e.id
            }
        }

        var date: Date {
            switch self {
            case .comment(let c): return c.date
            case .event(let e):   return e.date
            }
        }
    }

    /// Comments + events sorted oldest → newest, with attachment
    /// uploads merged INTO the comment they belong to (instead of
    /// floating as standalone "Você anexou X" rows next to the
    /// comment text the user actually typed).
    ///
    /// Two grouping signals, applied in order:
    ///
    ///  1. **API-level association** — when ClickUp returns the
    ///     attachment inline on a comment (the rare happy path
    ///     where the comment_id multipart anchor was honored),
    ///     dedup by attachment id.
    ///
    ///  2. **Time + author proximity** — the v2 attachment
    ///     endpoint does NOT honor `comment_id` reliably, so the
    ///     more common case is: comment lands at T, then N file
    ///     uploads land at T+1s … T+10s, all from the same user,
    ///     and ClickUp serves the comment with `attachments: []`.
    ///     Visually those should still group with the comment.
    ///     For each `attachmentAdded` event, find the most recent
    ///     comment from the same user posted within
    ///     `mergeWindow` seconds before — if found, merge the
    ///     attachment into that comment's bubble and consume the
    ///     event row.
    ///
    /// Events with no matching comment (drag-and-drop without a
    /// composer, AI-agent uploads, attachments from other users
    /// posted in isolation) keep their own event row.
    private var timeline: [TimelineEntry] {
        // Tunable: how long after a comment we'll still attach
        // late-arriving uploads. 90s comfortably covers the
        // worst-case multi-file upload from a slow connection
        // without grabbing unrelated later uploads.
        let mergeWindow: TimeInterval = 90

        let sortedComments = comments.sorted { $0.date < $1.date }
        let sortedEvents   = events.sorted { $0.date < $1.date }

        // 1. Build the API-inline set first (always trusted).
        let inlineAttachmentIds: Set<String> = Set(
            sortedComments.flatMap { $0.attachments.map(\.id) }
        )

        // 2. Walk attachmentAdded events and pair each with the
        //    most recent same-author comment within the window.
        //    `extrasByComment` carries the late-arriving files
        //    we'll splice into the comment's `attachments` for
        //    rendering; `consumedEventIds` records which event
        //    rows to suppress.
        var extrasByComment: [String: [CUTask.Attachment]] = [:]
        var consumedEventIds: Set<String> = []

        for event in sortedEvents {
            guard case .attachmentAdded(let att) = event.kind else { continue }

            // Skip uploads already inline on a comment — case 1.
            if inlineAttachmentIds.contains(att.id) {
                consumedEventIds.insert(event.id)
                continue
            }

            // Need an author to correlate with a comment author.
            // System-generated uploads (rare, e.g. integration
            // attachments) have no actor and never merge.
            guard let actorId = event.actor?.id else { continue }

            // Latest same-user comment posted at or before the
            // upload, within mergeWindow.
            let candidate = sortedComments.last { c in
                c.userId == actorId
                  && c.date <= event.date
                  && event.date.timeIntervalSince(c.date) <= mergeWindow
            }
            if let target = candidate {
                extrasByComment[target.id, default: []].append(att)
                consumedEventIds.insert(event.id)
            }
        }

        // 3. Rebuild comments with the spliced-in attachments.
        //    De-dup by id so a comment that ClickUp DID return
        //    inline plus an extra event-derived copy doesn't
        //    render twice.
        let augmentedComments: [CUComment] = sortedComments.map { c in
            guard let extras = extrasByComment[c.id], !extras.isEmpty else {
                return c
            }
            var all = c.attachments
            let existingIds = Set(all.map(\.id))
            for a in extras where !existingIds.contains(a.id) {
                all.append(a)
            }
            return CUComment(
                id:          c.id,
                text:        c.text,
                date:        c.date,
                userId:      c.userId,
                userName:    c.userName,
                userEmail:   c.userEmail,
                userColor:   c.userColor,
                initials:    c.initials,
                profilePic:  c.profilePic,
                resolved:    c.resolved,
                reactions:   c.reactions,
                replyCount:  c.replyCount,
                attachments: all
            )
        }

        // 4. Merge into the chronological timeline, dropping any
        //    event we already folded into a comment.
        var merged: [TimelineEntry] = []
        merged.reserveCapacity(augmentedComments.count + sortedEvents.count)
        merged.append(contentsOf: augmentedComments.map(TimelineEntry.comment))
        for e in sortedEvents where !consumedEventIds.contains(e.id) {
            // Hide the review-JSON upload event — it's surfaced as the
            // "Ver review" button on the review comment, not as a file row.
            if case .attachmentAdded(let att) = e.kind,
               att.title.hasPrefix("apollo-review") { continue }
            merged.append(.event(e))
        }
        return merged.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader

            if loading && timeline.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    .padding(.vertical, 12)
                if composerAtBottom { Spacer(minLength: 0) }
            } else if timeline.isEmpty {
                Text("Nenhuma atividade ainda.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                if composerAtBottom { Spacer(minLength: 0) }
            } else {
                // Comment list rendering depends on the host
                // surface — the section is reused in two very
                // different layouts:
                //
                //  • POPUP (composerAtBottom == true): the
                //    column is given a FIXED height by the
                //    parent HStack. Without an inner ScrollView
                //    the VStack grows to its content's
                //    intrinsic height — on tasks with rich
                //    comments (multi-line bodies, attachment
                //    cards) it overflows, dragging the
                //    composer offscreen and squeezing the
                //    sibling metadata column. That's the
                //    "abre certo e desconfigura quando os
                //    comentários carregam" bug: popup opens
                //    fine, network response lands, layout
                //    collapses. A ScrollView claiming
                //    `maxHeight: .infinity` claims the slot
                //    and scrolls overflow within it.
                //
                //  • INLINE (composerAtBottom == false): the
                //    section sits inside the parent's own
                //    ScrollView in the expanded task pill. An
                //    inner ScrollView would conflict with the
                //    outer one (nested scroll, gesture
                //    fighting). Let the VStack grow naturally
                //    and the parent handles overflow.
                if composerAtBottom {
                    // LazyVStack: only the comments visible inside
                    // the ScrollView's viewport mount initially.
                    // Each `commentRow` is heavy (avatar, body w/
                    // NSDataDetector parse, reactions row, replies
                    // section, attachment cards) — eagerly mounting
                    // 30+ rows up front was the dominant cost on
                    // the popup's open animation and on the first
                    // scroll past row ~10. Lazy mount cuts initial
                    // cost to roughly the viewport's worth (~5–7
                    // rows) and lets the scroll keep up.
                    // `.vertical` axis + `scrollBounceBehavior`
                    // on the horizontal axis fully locks the
                    // pan to vertical when content fits the
                    // viewport (which it always does — comment
                    // rows wrap to column width).
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 8) {
                            ForEach(timeline) { entry in
                                switch entry {
                                case .comment(let c): commentRow(c)
                                case .event(let e):   eventRow(e)
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .frame(maxHeight: .infinity)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(comments) { c in commentRow(c) }
                    }
                }
            }

            composer
        }
        .onAppear {
            // Both streams loaded together so a fresh popup
            // open kicks off one combined fetch — `refresh()`
            // dispatches comments + activity in parallel.
            if comments.isEmpty && events.isEmpty {
                Task { await refresh() }
            }
        }
        // Auto-reload when a review was just posted to THIS task (no manual
        // refresh) — so the review comment + its "Ver review" appear at once.
        .onChange(of: appState.reviewPostTick) { _, _ in
            if appState.reviewPostTaskId == task.id {
                Task { await refresh() }
            }
        }
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Editorial: a "Notas · N" folio, like a magazine
            // section opener — no icon, no filled count badge.
            Text(timeline.isEmpty ? "NOTAS" : "NOTAS · \(timeline.count)")
                .font(Editorial.sans(10.5, .semibold))
                .tracking(1.4)
                .foregroundStyle(Editorial.inkMute)
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: loading
                      ? "arrow.triangle.2.circlepath"
                      : "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Editorial.inkFaint)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(loading)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Single comment row (with reactions + replies)

    private func commentRow(_ c: CUComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            avatarBubble(name: c.userName ?? "?",
                         initials: c.initials,
                         color: c.userColor,
                         pic: c.profilePic)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(c.userName ?? "Sem nome")
                        .font(Editorial.sans(12.5, .semibold))
                        .foregroundStyle(Editorial.ink)
                    Text(relative(c.date))
                        .font(Editorial.serif(11).italic())
                        .foregroundStyle(Editorial.inkMute)
                    Spacer(minLength: 0)
                    rowMenu(for: c)
                }

                if c.text.isEmpty && c.attachments.isEmpty {
                    Text("(vazio)")
                        .font(Editorial.serif(13).italic())
                        .foregroundStyle(Editorial.inkMute)
                } else {
                    CommentBodyView(text: c.text,
                                    attachments: c.attachments,
                                    mentionUsernames: appState.availableMembers.map(\.username),
                                    reviewTaskId: task.id, reviewListId: task.listId,
                                    reviewActorId: reviewActorId, reviewActorName: reviewActorName,
                                    reviewCommentId: c.id)
                        .equatable()
                }

                // Reactions row
                if !c.reactions.isEmpty || emojiPickerFor == c.id {
                    reactionsRow(c)
                }

                // Quick actions: react + reply
                HStack(spacing: 12) {
                    Button {
                        emojiPickerFor = (emojiPickerFor == c.id) ? nil : c.id
                    } label: {
                        Label("Reagir", systemImage: "face.smiling")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .help("Adicionar reação")

                    Button {
                        toggleReplies(for: c)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 10))
                            Text(c.replyCount > 0 ? "Responder · \(c.replyCount)" : "Responder")
                                .font(Editorial.sans(11))
                        }
                        .foregroundStyle(Editorial.inkSoft)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }

                // Threaded replies
                if expandedReplies.contains(c.id) {
                    threadView(parentId: c.id)
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Editorial: a marginal "note" — no card, no
            // material. A 2pt cinnabar rule on the leading edge
            // (blockquote feel) instead.
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Editorial.accent.opacity(0.55))
                    .frame(width: 2)
            }
        }
    }

    private func rowMenu(for c: CUComment) -> some View {
        Menu {
            Button(role: .destructive) {
                Task {
                    await appState.deleteComment(c)
                    await refresh()
                }
            } label: { Label("Excluir", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
    }

    // MARK: - Reactions

    private func reactionsRow(_ c: CUComment) -> some View {
        HStack(spacing: 4) {
            ForEach(c.reactions, id: \.emoji) { r in
                let mine = isMyReaction(r)
                Button {
                    Task {
                        await appState.toggleCommentReaction(c, emoji: r.emoji,
                                                              currentlyReacted: mine)
                        await refresh()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(r.emoji)
                            .font(.system(size: 11))
                        Text("\(r.userIds.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(mine ? Editorial.accent : .secondary)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        mine ? AnyShapeStyle(Editorial.accent.opacity(0.15))
                             : AnyShapeStyle(Color.secondary.opacity(0.10)),
                        in: Capsule()
                    )
                    .overlay(Capsule().strokeBorder(
                        mine ? Editorial.accent.opacity(0.45)
                             : Color.secondary.opacity(0.25),
                        lineWidth: 0.5))
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }

            if emojiPickerFor == c.id {
                ForEach(quickEmojis, id: \.self) { e in
                    Button {
                        let mine = c.reactions.first { $0.emoji == e }
                            .map(isMyReaction) ?? false
                        Task {
                            await appState.toggleCommentReaction(c, emoji: e,
                                                                  currentlyReacted: mine)
                            emojiPickerFor = nil
                            await refresh()
                        }
                    } label: {
                        Text(e)
                            .font(.system(size: 13))
                            .padding(4)
                            .background(Color.primary.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                }
                Button { emojiPickerFor = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        }
    }

    /// Heuristic: we don't have the current user's ClickUp ID exposed,
    /// so treat a reaction as "mine" when the first author of the
    /// comment list (i.e. the local user) appears in the userIds set.
    private func isMyReaction(_ r: CUComment.Reaction) -> Bool {
        guard let myId = comments.first?.userId else { return false }
        return r.userIds.contains(myId)
    }

    // MARK: - Replies

    private func toggleReplies(for c: CUComment) {
        if expandedReplies.contains(c.id) {
            expandedReplies.remove(c.id)
        } else {
            expandedReplies.insert(c.id)
            Task {
                let r = await appState.loadReplies(to: c.id)
                await MainActor.run { repliesByParent[c.id] = r.sorted { $0.date < $1.date } }
            }
        }
    }

    private func threadView(parentId: String) -> some View {
        // LazyVStack so threads with 10+ replies don't pay the
        // per-reply mount cost (avatar, body parse, attachment
        // cards) up front when the user expands the thread.
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(repliesByParent[parentId] ?? []) { r in
                replyRow(r)
            }
            replyComposer(parentId: parentId)
        }
        .padding(.leading, 8)
        .padding(.top, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1.5)
        }
    }

    private func replyRow(_ r: CUComment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            avatarBubble(name: r.userName ?? "?", initials: r.initials,
                         color: r.userColor, pic: r.profilePic)
                .scaleEffect(0.85)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.userName ?? "Sem nome")
                        .font(.caption2.weight(.semibold))
                    Text(relative(r.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                CommentBodyView(text: r.text,
                                attachments: r.attachments,
                                mentionUsernames: appState.availableMembers.map(\.username),
                                reviewTaskId: task.id, reviewListId: task.listId,
                                reviewActorId: reviewActorId, reviewActorName: reviewActorName,
                                reviewCommentId: r.id)
                    .equatable()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func replyComposer(parentId: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            TextField("Responder…",
                      text: Binding(
                        get: { replyDrafts[parentId] ?? "" },
                        set: { replyDrafts[parentId] = $0 }
                      ))
                .textFieldStyle(.plain)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))

            Button {
                let txt = (replyDrafts[parentId] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !txt.isEmpty else { return }
                Task {
                    if let posted = await appState.postReply(to: parentId, text: txt) {
                        await MainActor.run {
                            repliesByParent[parentId, default: []].append(posted)
                            replyDrafts[parentId] = ""
                        }
                    }
                    await refresh()
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Editorial.accent, in: Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .disabled(((replyDrafts[parentId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if uploading {
                uploadProgressBar
            }

            // Mention picker lives ABOVE the input pill so the
            // composer's anchor (the pill itself) stays at a
            // fixed Y-position when the picker grows / shrinks.
            // Mirroring how Slack, Linear, and ClickUp's web
            // client behave — suggestions float upward from
            // the input rather than push it around the screen.
            if let q = mentionQuery, !filteredMembers(matching: q).isEmpty {
                mentionPicker(query: q)
            }

            // ── ClickUp-style auto-growing composer ──────────
            //
            // The composer is now a VStack with the text on top
            // and the toolbar pinned underneath, both wrapped in
            // a single rounded-rect container. Critical bits:
            //
            //  1. `TextField(axis: .vertical)` (macOS 13+)
            //     intrinsically multi-line. Pressing Return
            //     inserts a newline; Cmd+Return submits via the
            //     `.onKeyPress` handler below. This matches
            //     ClickUp / Slack / Linear chat-input semantics.
            //
            //  2. `.lineLimit(1...8)` lets the field grow from
            //     a 1-line baseline up to 8 lines, then scrolls
            //     internally. The whole VStack therefore grows
            //     too, and the parent ScrollView absorbs the
            //     pressure by pushing the comment list up
            //     (composerAtBottom layout) — same UX as
            //     ClickUp's panel.
            //
            //  3. The previous Capsule + fixed-22pt TextEditor
            //     could ONLY render one line. Multi-line input
            //     visibly clipped past the first row, the
            //     trailing send button stayed on the first line,
            //     and Return inserted a newline that the user
            //     never saw. RoundedRectangle + VStack fixes
            //     all three in one shot.
            VStack(alignment: .leading, spacing: 0) {
                // Pending-attachment chips — rendered ABOVE the
                // textfield so the user sees what will go out
                // alongside the typed message. Same visual model
                // as ClickUp's web composer: each file is a
                // capsule with icon + name + X. Files only flush
                // to ClickUp on send; until then they're
                // ephemeral state that can be removed freely.
                if !pendingAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pendingAttachments, id: \.self) { url in
                            pendingAttachmentChip(url)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                TextField(
                    "Escreva um comentário…  •  use @ para mencionar",
                    text: $draft,
                    axis: .vertical
                )
                .focused($draftFocused)
                .focusEffectDisabled()
                .textFieldStyle(.plain)
                .font(Editorial.serif(13))
                .foregroundStyle(Editorial.ink)
                .lineLimit(1...8)
                .padding(.horizontal, 12)
                .padding(.top, pendingAttachments.isEmpty ? 10 : 8)
                .padding(.bottom, 6)
                .onChange(of: draft) { _, new in updateMentionState(text: new) }
                // Cmd+Return submits without inserting a
                // newline. Plain Return falls through to the
                // TextField's default newline-insert behaviour
                // (the right call for a multi-line composer —
                // shoving Return = send would surprise users
                // who paste multi-paragraph text).
                .onKeyPress(.return, phases: .down) { event in
                    if event.modifiers.contains(.command) {
                        Task { await send() }
                        return .handled
                    }
                    return .ignored
                }

                // ── Toolbar row (pinned to the bottom) ─────
                // Paperclip on the left, send on the right.
                // Sits inside the same rounded container as
                // the text so the whole control reads as one
                // chat input that grows together.
                HStack(alignment: .center, spacing: 6) {
                    Button {
                        pickFilesIntoPending()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Editorial.inkSoft)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .disabled(uploading || posting)
                    .help("Anexar arquivo")

                    Spacer(minLength: 0)

                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: posting
                              ? "ellipsis" : "paperplane.fill")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(canSend
                                             ? Editorial.accent
                                             : Editorial.inkFaint)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .disabled(!canSend)
                    .help("Enviar comentário (⌘⏎)")
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
            // Editorial: a paper input — white surface, hairline
            // rule, near-square corners (prototype composer).
            .background(
                Editorial.page,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        isDropTargeted || draftFocused
                            ? Editorial.accent.opacity(0.55)
                            : Editorial.rule,
                        lineWidth: isDropTargeted ? 1.5 : 1
                    )
            )
            // Accept file drops anywhere on the composer surface.
            // The `loadObject(ofClass: URL.self)` path covers
            // drags from Finder, Mail attachments, Safari
            // downloads, iMessage media — anything that
            // advertises `public.file-url`.
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
            }
            // Clicking ANYWHERE inside the box (the placeholder
            // area, padding, around the icons) focuses the field —
            // keeps the active-mode handoff feeling instant.
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { draftFocused = true }
            .animation(.easeInOut(duration: 0.18), value: draftFocused)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: pendingAttachments)
        }
    }

    // MARK: - Pending attachment chip

    private func pendingAttachmentChip(_ url: URL) -> some View {
        let ext  = url.pathExtension.lowercased()
        return HStack(spacing: 8) {
            Image(systemName: chipIcon(forExtension: ext))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(chipTint(forExtension: ext))
                .frame(width: 16)

            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Button {
                withAnimation { pendingAttachments.removeAll { $0 == url } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Remover anexo")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10),
                              lineWidth: 0.5)
        )
    }

    private func chipIcon(forExtension ext: String) -> String {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv":           return "play.rectangle"
        case "mp3", "wav", "m4a", "aac", "flac":          return "waveform"
        case "pdf":                                       return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz":             return "shippingbox"
        case "txt", "md", "rtf":                          return "doc.text"
        case "csv", "xlsx", "xls", "numbers":             return "tablecells"
        case "key", "ppt", "pptx":                        return "rectangle.on.rectangle"
        case "doc", "docx", "pages":                      return "doc"
        default:                                          return "paperclip"
        }
    }

    private func chipTint(forExtension ext: String) -> Color {
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return .pink
        case "mp4", "mov", "m4v", "avi", "mkv":           return .indigo
        case "mp3", "wav", "m4a", "aac", "flac":          return .purple
        case "pdf":                                       return .red
        case "zip", "rar", "7z", "tar", "gz":             return .brown
        case "csv", "xlsx", "xls", "numbers":             return .green
        case "key", "ppt", "pptx":                        return .orange
        case "doc", "docx", "pages":                      return .blue
        default:                                          return Editorial.accent
        }
    }

    // MARK: - Pending-attachment drop / pick

    /// Open NSOpenPanel (multi-select, any type) and append the
    /// chosen URLs to `pendingAttachments`. Replaces the previous
    /// `pickAndUpload` flow that fired uploads immediately —
    /// files now queue and ship together with the typed message
    /// on send.
    private func pickFilesIntoPending() {
        let panel = NSOpenPanel()
        panel.title                   = "Anexar ao comentário"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.allowedContentTypes     = []
        guard panel.runModal() == .OK else { return }
        appendPending(panel.urls)
    }

    /// Drain dropped NSItemProviders. URL resolution can be
    /// asynchronous (Mail attachments / Continuity screenshots
    /// materialize the file lazily), so each provider loads off
    /// the main thread and the append happens back on main.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { appendPending([url]) }
            }
        }
        return true
    }

    /// De-duplicated append. Same URL dragged twice stays as one
    /// entry — matches what `CreateTaskSheet` does for its own
    /// attachment list.
    private func appendPending(_ urls: [URL]) {
        for url in urls where !pendingAttachments.contains(url) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                pendingAttachments.append(url)
            }
        }
        // Focus the field after a drop so ⌘⏎ works without a
        // mouse round-trip — matches ClickUp's drag-to-reply UX.
        draftFocused = true
    }

    /// Allows send when there's actual content to ship — either
    /// typed text OR queued attachments. The legacy rule
    /// ("text non-empty") would have stranded files in the
    /// composer after a drag-only flow.
    private var canSend: Bool {
        guard !posting && !uploading else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !pendingAttachments.isEmpty
    }

    /// Live upload bar shown above the composer while a file is in flight.
    private var uploadProgressBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.doc.fill")
                .font(.callout)
                .foregroundStyle(Editorial.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(uploadFilename ?? "Enviando…")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if uploadTotal > 1 {
                        Text("(\(uploadIndex)/\(uploadTotal))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text("\(Int(uploadProgress * 100))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: uploadProgress)
                    .progressViewStyle(.linear)
                    .tint(Editorial.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Mentions

    /// Tracks the trailing "@xxx" token in the composer so we can offer a
    /// member picker. Matching is case-insensitive against username.
    private func updateMentionState(text: String) {
        // Find the substring after the last "@" that has no whitespace.
        guard let atIdx = text.lastIndex(of: "@") else {
            mentionQuery = nil; return
        }
        let after = text.index(after: atIdx)
        let trailing = String(text[after...])
        if trailing.contains(where: { $0.isWhitespace || $0.isNewline }) {
            mentionQuery = nil
        } else {
            mentionQuery = trailing.lowercased()
        }
    }

    private func filteredMembers(matching q: String) -> [CUMember] {
        guard !appState.availableMembers.isEmpty else { return [] }
        if q.isEmpty { return Array(appState.availableMembers.prefix(6)) }
        return appState.availableMembers
            .filter { $0.username.lowercased().contains(q) }
            .prefix(6)
            .map { $0 }
    }

    private func mentionPicker(query: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredMembers(matching: query)) { m in
                Button {
                    insertMention(m)
                } label: {
                    HStack(spacing: 8) {
                        let bg = (m.color.flatMap { Color(hex: $0) }
                                  ?? Editorial.inkMute).editorialMuted
                        ZStack {
                            Circle().fill(bg)
                            Text(m.initials ?? String(m.username.prefix(2)).uppercased())
                                .font(Editorial.sans(8, .bold))
                                .foregroundStyle(Editorial.page)
                        }
                        .frame(width: 18, height: 18)
                        Text("@" + m.username)
                            .font(Editorial.sans(12, .medium))
                            .foregroundStyle(Editorial.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                if m.id != filteredMembers(matching: query).last?.id {
                    Rectangle().fill(Editorial.ruleSoft).frame(height: 1)
                }
            }
        }
        .background(
            Editorial.page,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Editorial.rule, lineWidth: 1))
        .padding(.leading, 40)
    }

    private func insertMention(_ m: CUMember) {
        // Replace trailing "@<query>" with "@<username> ".
        guard let atIdx = draft.lastIndex(of: "@") else { return }
        let prefix = draft[..<atIdx]
        draft = prefix + "@" + m.username + " "
        mentionQuery = nil
        // Track the resolved member ID so `send()` can pass
        // it to ClickUp's API and trigger a real
        // mention-notification. De-dupe in case the user
        // mentions the same person twice.
        if !mentionedIds.contains(m.id) {
            mentionedIds.append(m.id)
        }
    }

    // MARK: - Attachment

    // MARK: - Networking helpers

    private func refresh() async {
        loading = true
        // Comments and activity events come from independent
        // ClickUp endpoints. Fetch them concurrently via async
        // let so the popup paints in roughly one round-trip
        // instead of two — about 200–400ms saved on the
        // typical popup open. Both responses are awaited
        // together below before we update SwiftUI state.
        async let freshComments = appState.loadComments(for: task)
        async let freshEvents   = appState.loadActivity(for: task)
        let (cs, es) = await (freshComments, freshEvents)
        await MainActor.run {
            self.comments = cs.sorted { $0.date < $1.date }
            self.events   = es
            self.loading  = false
        }
        // Re-fetch any expanded threads so reaction/reply counts stay live.
        for parentId in expandedReplies {
            let r = await appState.loadReplies(to: parentId)
            await MainActor.run { repliesByParent[parentId] = r.sorted { $0.date < $1.date } }
        }
    }

    /// Unified send path: posts the typed comment (if any), then
    /// uploads each pending attachment anchored to that comment's
    /// id. The result lands as ONE bubble in the timeline (text +
    /// files), matching ClickUp's web composer flow. Each upload
    /// shows progress via the existing `uploadProgressBar`.
    ///
    /// Edge cases:
    /// - text-only → behave like the legacy send.
    /// - files-only (no text) → post a single-space comment so
    ///   ClickUp's API accepts it (`comment_text` must be
    ///   non-empty), then attach the files to that bubble.
    /// - text + files → post comment, then upload each file with
    ///   `commentId` so they land inside the same bubble.
    /// - post failure → keep the draft + pending files so the
    ///   user doesn't lose their work; surface error via the
    ///   existing notify path inside `appState.postComment`.
    private func send() async {
        let txt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingAttachments
        guard !txt.isEmpty || !files.isEmpty else { return }

        // Trim `mentionedIds` to those whose "@username"
        // still appears in the final draft.
        let lower = txt.lowercased()
        let liveMentions = mentionedIds.filter { id in
            guard let m = appState.availableMembers.first(where: { $0.id == id }) else {
                return false
            }
            return lower.contains("@" + m.username.lowercased())
        }

        await MainActor.run { posting = true }

        // ── 1. Post the comment ────────────────────────────
        // If the user only attached files (no typed message),
        // ClickUp still expects a non-empty `comment_text`. A
        // single space is the smallest value that keeps the
        // bubble rendering essentially "files only".
        let commentBody = txt.isEmpty ? " " : txt
        let posted = await appState.postComment(
            on: task,
            text: commentBody,
            mentionedMemberIds: liveMentions
        )

        // ── 2. Upload pending attachments anchored to the new
        //       comment, so they land inside the same bubble.
        //       If the post failed we still try the uploads —
        //       they'll appear as plain task attachments rather
        //       than orphaning the files the user dragged in.
        if !files.isEmpty {
            withAnimation(.easeInOut(duration: 0.18)) {
                uploading      = true
                uploadTotal    = files.count
                uploadIndex    = 0
                uploadProgress = 0
            }
            for (i, url) in files.enumerated() {
                await MainActor.run {
                    uploadFilename = url.lastPathComponent
                    uploadIndex    = i + 1
                    uploadProgress = 0
                }
                _ = await appState.uploadCommentAttachment(
                    for:       task,
                    fileURL:   url,
                    commentId: posted?.id
                ) { p in
                    Task { @MainActor in
                        if abs(p - uploadProgress) > 0.005 || p >= 1.0 {
                            withAnimation(.linear(duration: 0.1)) {
                                uploadProgress = p
                            }
                        }
                    }
                }
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                uploading      = false
                uploadFilename = nil
                uploadProgress = 0
            }
        }

        // ── 3. Reset composer + reconcile the timeline ─────
        // If `posted` is non-nil we trust it as the canonical
        // record; otherwise we refresh from the server to pull
        // back whatever did land (the upload may have created
        // its own activity entries even if the comment POST
        // failed).
        if posted != nil && files.isEmpty {
            await MainActor.run {
                if let p = posted { self.comments.append(p) }
            }
        } else {
            await refresh()
        }
        await MainActor.run {
            self.draft = ""
            self.mentionedIds = []
            self.pendingAttachments = []
            posting = false
            mentionQuery = nil
        }
    }

    // MARK: - Activity event row

    /// One non-comment row in the timeline. Compact layout: an
    /// icon dot at the avatar position aligns the row visually
    /// with comment rows, followed by a single-line natural-
    /// language summary and a relative timestamp on the right.
    /// Some event kinds (currently just `attachmentAdded`)
    /// expand into a richer secondary card under the line —
    /// uploads in particular benefit from the file thumbnail
    /// since that's the user's main "did the file actually go
    /// through?" signal.
    private func eventRow(_ event: TaskActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            eventIconBubble(event)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    eventSummary(event)
                    Spacer(minLength: 4)
                    Text(relative(event.date))
                        .font(Editorial.serif(11).italic())
                        .foregroundStyle(Editorial.inkMute)
                        .lineLimit(1)
                        .fixedSize()
                }
                eventTrailingContent(event)
            }
        }
        .padding(.vertical, 2)
    }

    /// 22pt circle wrapping an SF Symbol — matches the avatar
    /// dimension on `commentRow` so events and comments align
    /// visually down a single column.
    private func eventIconBubble(_ event: TaskActivityEvent) -> some View {
        ZStack {
            Circle().fill(Editorial.ruleSoft)
            Image(systemName: event.iconName)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Editorial.inkMute)
        }
        .frame(width: 22, height: 22)
    }

    /// Natural-language one-liner per event kind. Composed
    /// from styled `Text` runs so values (status names, file
    /// names, assignee names) can be emphasised without
    /// resorting to attributed strings. Falls back to the
    /// `.unknown` summary string for unmapped fields.
    @ViewBuilder
    private func eventSummary(_ event: TaskActivityEvent) -> some View {
        let actorName = displayActorName(event.actor)

        switch event.kind {
        case .taskCreated:
            eventLine(actorName, "criou a tarefa")

        case .statusChanged(let from, let to):
            HStack(spacing: 4) {
                eventLine(actorName, "mudou status")
                if let from { statusChip(from) }
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                if let to   { statusChip(to) }
            }

        case .assigneeAdded(let user):
            eventLine(actorName,
                      "atribuiu a \(displayActorName(user))")
        case .assigneeRemoved(let user):
            eventLine(actorName,
                      "removeu \(displayActorName(user))")

        case .attachmentAdded(let att):
            eventLine(actorName, "anexou \(att.title)")
        case .attachmentRemoved(let att):
            eventLine(actorName, "removeu o anexo \(att.title)")

        case .nameChanged(_, let to):
            if let to {
                eventLine(actorName, "renomeou para \"\(to)\"")
            } else {
                eventLine(actorName, "renomeou a tarefa")
            }

        case .priorityChanged(_, let to):
            eventLine(actorName,
                      "mudou prioridade para \(to?.name ?? "—")")

        case .dueDateChanged(_, let to):
            eventLine(actorName,
                      to.map { "definiu vencimento para \(formattedDate($0))" }
                        ?? "removeu o vencimento")

        case .startDateChanged(_, let to):
            eventLine(actorName,
                      to.map { "definiu início para \(formattedDate($0))" }
                        ?? "removeu a data de início")

        case .descriptionChanged:
            eventLine(actorName, "editou a descrição")

        case .tagAdded(let name, _, _):
            eventLine(actorName, "adicionou a tag \(name)")
        case .tagRemoved(let name, _, _):
            eventLine(actorName, "removeu a tag \(name)")

        case .subtaskAdded(let name, _):
            eventLine(actorName,
                      "criou a subtarefa \(name ?? "(sem título)")")

        case .parentChanged(_, let to):
            eventLine(actorName,
                      to.map { "moveu para \($0)" } ?? "removeu o pai")
        case .listChanged(_, let to):
            eventLine(actorName,
                      to.map { "moveu para a lista \($0)" } ?? "saiu da lista")

        case .archived:
            eventLine(actorName, "arquivou a tarefa")
        case .unarchived:
            eventLine(actorName, "desarquivou a tarefa")

        case .unknown(_, let summary):
            eventLine(actorName, summary)
        }
    }

    /// Two-segment headline: bold actor + regular description.
    /// Wrapped in a single `Text` (via `+`) so SwiftUI lays it
    /// out as one wrappable line instead of two HStack pieces
    /// that would force-fit on narrow popups.
    private func eventLine(_ actor: String, _ rest: String) -> some View {
        (Text(actor).font(Editorial.sans(12.5, .semibold))
            .foregroundColor(Editorial.ink)
         + Text(" \(rest)").font(Editorial.sans(12.5))
            .foregroundColor(Editorial.inkSoft))
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Resolves the visible name for an event actor. Empty /
    /// missing → "Alguém". When the actor is the connected
    /// ClickUp user, swap in "Você" so the user instantly sees
    /// which rows are their own.
    private func displayActorName(_ actor: CUTask.Assignee?) -> String {
        if let me = appState.clickUpAuthService.userId,
           actor?.id == me { return "Você" }
        return actor?.username ?? "Alguém"
    }

    /// Inline status chip — same colour scheme used everywhere
    /// else in the app (`Color(hex:)` over an opaque capsule
    /// with white uppercase text).
    private func statusChip(_ ref: TaskActivityEvent.StatusRef) -> some View {
        // Editorial: status as a muted dot + word, never a
        // white-on-saturated capsule.
        let color = ref.hex.flatMap { Color(hex: $0).editorialMuted }
            ?? Editorial.inkMute
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(ref.name)
                .font(Editorial.sans(11, .medium))
                .foregroundStyle(Editorial.inkSoft)
        }
    }

    /// Date formatter used by date-change rows. Lighter than
    /// `RelativeDateTimeFormatter` (which is reserved for the
    /// row's "X minutos" timestamp) — the inline date wants to
    /// be unambiguous, e.g. "12 mai".
    private func formattedDate(_ date: Date) -> String {
        date.formatted(.dateTime
            .day().month(.abbreviated)
            .locale(Locale(identifier: "pt_BR")))
    }

    /// Optional richer card below the headline. Only
    /// attachment-add events get one for now — the file card
    /// is the same shape as the comment-attachment card so the
    /// timeline reads consistently.
    @ViewBuilder
    private func eventTrailingContent(_ event: TaskActivityEvent) -> some View {
        switch event.kind {
        case .attachmentAdded(let att):
            attachmentEventCard(att)
        default:
            EmptyView()
        }
    }

    /// Compact attachment card — opens the URL in the default
    /// browser on click. Mirrors `CommentBodyView.structuredCard`
    /// but lives inside this section to avoid coupling the two
    /// view files (and to keep the click target sized for the
    /// tighter timeline row).
    /// Connected ClickUp user, for the REVIEW deep link's actor.
    private var reviewActorId: Int? { appState.clickUpAuthService.userId }
    private var reviewActorName: String {
        let id = appState.clickUpAuthService.userId
        return appState.availableMembers.first { $0.id == id }?.username ?? "Revisor"
    }

    private func attachmentEventCard(_ att: CUTask.Attachment) -> some View {
        let url = URL(string: att.url) ?? URL(fileURLWithPath: "/")
        // Muted file-type accent — coherent with the global
        // editorial densify/desaturate rule.
        let accent = Color(hex: att.accentHex).editorialMuted
        return Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // Editorial: a small uppercase file-type tag in
                // the muted type colour over a faint tint — no
                // glossy/coloured icon plate.
                Text(att.ext.isEmpty ? "FILE" : att.ext.uppercased())
                    .font(Editorial.sans(9, .semibold))
                    .tracking(0.4)
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(att.title)
                        .font(Editorial.serif(13))
                        .foregroundStyle(Editorial.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let s = att.sizeString, !s.isEmpty {
                        Text(s)
                            .font(Editorial.sans(10.5))
                            .foregroundStyle(Editorial.inkMute)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)

                if ReviewLink.isReviewable(att.ext), let aid = reviewActorId {
                    Button {
                        ReviewPresenter.shared.present(
                            ReviewLink.params(attachment: att, taskId: task.id, listId: task.listId,
                                              uploaderId: att.uploaderId,
                                              actorId: aid, actorName: reviewActorName))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("REVIEW")
                                .font(Editorial.sans(9.5, .bold))
                                .tracking(0.4)
                        }
                        .foregroundStyle(Editorial.page)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Editorial.accent))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Abrir no Apollo Review")
                }

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Editorial.inkMute)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Editorial.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Editorial.rule, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Abrir \(att.title)")
    }

    // MARK: - Display helpers

    private func avatarBubble(name: String, initials: String?,
                              color: String?, pic: String?) -> some View {
        let bg = color.flatMap { Color(hex: $0) } ?? .blue
        return ZStack {
            Circle().fill(bg)
            if let pic, let url = URL(string: pic) {
                // CachedAvatar hits an in-memory NSCache and
                // dedupes in-flight requests across views.
                // Plain `AsyncImage` was kicking off a fresh
                // URLSession fetch every time a comment row
                // re-mounted via LazyVStack during scroll —
                // 30 visible comments × 1 fetch per scroll-in
                // event was the dominant network/CPU cost in
                // the comments column.
                CachedAvatar(url: url)
                    .clipShape(Circle())
            } else {
                Text(initials ?? String(name.prefix(2)).uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale     = Locale(identifier: "pt-BR")
        return f.localizedString(for: date, relativeTo: Date())
    }
}
