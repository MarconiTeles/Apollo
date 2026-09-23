import SwiftUI

// Universal "skeleton" placeholder row — a desaturated stand-in painted
// while real data is in flight, shaped like the task row it will become so
// the user perceives "rows are coming" instead of "nothing's here".
//
// The shapes are a mask for `LunarSkeletonSurface`, which paints the resting
// tone and the moonlight sweep shared by every placeholder on screen.

struct EditorialSkeletonRow: View {
    var body: some View {
        LunarSkeletonSurface { EditorialSkeletonRowShapes() }
    }
}

/// Mask shapes for one task row. Used on its own by `EditorialSkeletonStack`
/// so a whole list shares a single surface (one clock, one mask).
struct EditorialSkeletonRowShapes: View {
    var body: some View {
        HStack(spacing: 12) {
            // Status dot stand-in
            Circle()
                .fill(LunarSkeleton.primary)
                .frame(width: 7, height: 7)
            // Two-line text stand-in — title + caption widths
            // chosen to read as a task row at a glance.
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LunarSkeleton.primary)
                    .frame(height: 11)
                    .frame(maxWidth: 260)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(LunarSkeleton.secondary)
                    .frame(height: 8)
                    .frame(maxWidth: 110)
            }
            Spacer(minLength: 12)
            // Trailing date stand-in
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LunarSkeleton.secondary)
                .frame(width: 56, height: 10)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(LunarSkeleton.faint)
                .frame(height: 0.5)
        }
    }
}

/// Convenience stack — N skeleton rows under one lunar surface, the drop-in
/// replacement for the `Color.clear` empty-while-syncing pattern. Defaults
/// to 8 rows which covers a typical viewport without scrolling.
struct EditorialSkeletonStack: View {
    var count: Int = 8

    var body: some View {
        LunarSkeletonSurface {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    EditorialSkeletonRowShapes()
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
    }
}
