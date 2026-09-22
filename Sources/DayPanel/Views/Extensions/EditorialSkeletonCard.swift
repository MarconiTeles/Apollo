import SwiftUI

// Card-shaped placeholder for the Quadro (kanban) view while
// tasks are loading. Matches `BoardCard`'s layout shorthand —
// a top breadcrumb bar, a stacked title block, and a footer
// avatar + date — but rendered with desaturated `Editorial.rule`
// rectangles. Pulses softly via opacity to read as "things are
// arriving", not "empty placeholder".
//
// Used by `EditorialBoardView.column(for:)` only on cold-start
// (no `appState.tasks` loaded yet AND `isSyncing`). Once tasks
// land the real `BoardCard`s replace it; an empty column with
// loaded data shows nothing instead of skeletons (matches the
// gating rules in TaskListView / EditorialMyTasksView).

struct EditorialSkeletonCard: View {
    @State private var pulse: Bool = false
    private let minOpacity: Double = 0.35

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top row: dot + breadcrumb caps stand-in
            HStack(spacing: 8) {
                Circle()
                    .fill(Editorial.rule)
                    .frame(width: 6, height: 6)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule.opacity(0.7))
                    .frame(height: 8)
                    .frame(maxWidth: 140)
            }
            // Title stand-in — 2 lines of varying width
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule)
                    .frame(height: 13)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule.opacity(0.8))
                    .frame(height: 13)
                    .frame(maxWidth: 180)
            }
            // Footer: avatar + name + date stand-ins
            HStack(spacing: 8) {
                Circle()
                    .fill(Editorial.rule)
                    .frame(width: 18, height: 18)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule.opacity(0.65))
                    .frame(height: 9)
                    .frame(maxWidth: 60)
                Spacer(minLength: 4)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule.opacity(0.55))
                    .frame(width: 48, height: 9)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Editorial.page)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Editorial.rule.opacity(0.4), lineWidth: 0.5)
        )
        .opacity(pulse ? 1.0 : minOpacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
