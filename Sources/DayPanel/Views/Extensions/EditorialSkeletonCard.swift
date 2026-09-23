import SwiftUI

// Card-shaped placeholder for the Quadro (kanban) view while
// tasks are loading. Matches `BoardCard`'s layout shorthand —
// a top breadcrumb bar, a stacked title block, and a footer
// avatar + date — as a mask for `LunarSkeletonSurface`, so the card is
// lit by the same moonlight sweep as every other placeholder on screen.
//
// Used by `EditorialBoardView.column(for:)` only on cold-start
// (no `appState.tasks` loaded yet AND `isSyncing`). Once tasks
// land the real `BoardCard`s replace it; an empty column with
// loaded data shows nothing instead of skeletons (matches the
// gating rules in TaskListView / EditorialMyTasksView).

struct EditorialSkeletonCard: View {
    var body: some View {
        LunarSkeletonSurface {
            VStack(alignment: .leading, spacing: 12) {
                // Top row: dot + breadcrumb caps stand-in
                HStack(spacing: 8) {
                    Circle()
                        .fill(LunarSkeleton.primary)
                        .frame(width: 6, height: 6)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LunarSkeleton.secondary)
                        .frame(height: 8)
                        .frame(maxWidth: 140)
                }
                // Title stand-in — 2 lines of varying width
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LunarSkeleton.primary)
                        .frame(height: 13)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LunarSkeleton.primary)
                        .frame(height: 13)
                        .frame(maxWidth: 180)
                }
                // Footer: avatar + name + date stand-ins
                HStack(spacing: 8) {
                    Circle()
                        .fill(LunarSkeleton.primary)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LunarSkeleton.secondary)
                        .frame(height: 9)
                        .frame(maxWidth: 60)
                    Spacer(minLength: 4)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LunarSkeleton.faint)
                        .frame(width: 48, height: 9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Editorial.page)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule.opacity(0.4), lineWidth: 0.5)
        )
    }
}
