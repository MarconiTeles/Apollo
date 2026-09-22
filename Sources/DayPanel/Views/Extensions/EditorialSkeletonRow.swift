import SwiftUI

// Universal "skeleton" placeholder row — a desaturated stand-in
// painted while real data is in flight. Replaces the previous
// `Color.clear` empty-while-syncing pattern that made the canvas
// look broken before the first network round-trip returned.
//
// Design intent: NOT a flashy spinner. A row-shaped pulse that
// roughly matches the layout the real rows will land in, so the
// user perceives "rows are coming" instead of "nothing's here".
// When data lands the skeleton ForEach gives way to the real
// data ForEach + cascade fade-in — feels like the placeholders
// resolved into actual rows.

struct EditorialSkeletonRow: View {
    /// Drives the soft pulse — fades the whole row between
    /// `minOpacity` and 1 in a slow 1.4s autoreverse loop. Subtle
    /// enough to feel like breathing, not strobe.
    @State private var pulse: Bool = false
    private let minOpacity: Double = 0.35

    var body: some View {
        HStack(spacing: 12) {
            // Status dot stand-in
            Circle()
                .fill(Editorial.rule)
                .frame(width: 7, height: 7)
            // Two-line text stand-in — title + caption widths
            // chosen to read as a task row at a glance.
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule)
                    .frame(height: 11)
                    .frame(maxWidth: 260)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Editorial.rule.opacity(0.55))
                    .frame(height: 8)
                    .frame(maxWidth: 110)
            }
            Spacer(minLength: 12)
            // Trailing date stand-in
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Editorial.rule.opacity(0.65))
                .frame(width: 56, height: 10)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .opacity(pulse ? 1.0 : minOpacity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Editorial.rule.opacity(0.5))
                .frame(height: 0.5)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Convenience stack — N skeleton rows with cascade fade-in, the
/// drop-in replacement for the `Color.clear` empty-while-syncing
/// pattern. Defaults to 8 rows which covers a typical viewport
/// without scrolling.
struct EditorialSkeletonStack: View {
    var count: Int = 8

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                EditorialSkeletonRow()
                    .cascadeAppear(index: i)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .allowsHitTesting(false)
    }
}
