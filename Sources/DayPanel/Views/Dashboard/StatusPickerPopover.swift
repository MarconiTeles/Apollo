import SwiftUI

/// Canonical status-selection list used everywhere a user picks a
/// ClickUp status. Renders the workspace's available statuses as a
/// vertical list with the canonical colour for each label and a
/// checkmark on the current selection — same look across the task row,
/// task detail (inline + popup), and the create-task form.
///
/// The component is intentionally agnostic about *what* changes when a
/// status is picked — callers pass an `onSelect(CUStatus)` closure
/// that receives the chosen status and decides whether to:
///   - mutate AppState (TaskRowView / TaskDetailView edit flows), or
///   - just update local @State (CreateTaskSheet new-task flow).
struct StatusPickerPopover: View {
    let statuses: [CUStatus]
    let currentStatusName: String?
    /// Rows cascade in while the surrounding glass grows.
    var revealed: Bool = true
    /// The cascade starts at the side nearest the click: bottom-up when the
    /// list opens above the control, top-down when it opens below.
    var revealFromBottom = false
    let onSelect: (CUStatus) -> Void

    @State private var hovered: String?
    @Namespace private var highlightNamespace

    private static let rowHeight: CGFloat = 28
    private static let inset: CGFloat = 6

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                    row(status, index: index)
                }
            }
            .padding(Self.inset)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.never)
        .onHover { inside in
            if !inside { withAnimation(.easeOut(duration: 0.18)) { hovered = nil } }
        }
    }

    private func cascadeStep(_ index: Int) -> Int {
        revealFromBottom ? statuses.count - 1 - index : index
    }

    private func row(_ status: CUStatus, index: Int) -> some View {
        let isSelected = status.status.caseInsensitiveCompare(currentStatusName ?? "") == .orderedSame
        let color = Color(statusHex: status.displayHex)
        return Button {
            onSelect(status)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .scaleEffect(hovered == status.id ? 1.25 : 1)
                Text(status.status.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background {
                // One highlight that slides between rows instead of each
                // row flashing its own background.
                if hovered == status.id {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(color.opacity(0.16))
                        .matchedGeometryEffect(id: "highlight", in: highlightNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            guard inside else { return }
            withAnimation(.spring(duration: 0.26, bounce: 0.18)) { hovered = status.id }
        }
        .opacity(revealed ? 1 : 0)
        .blur(radius: revealed ? 0 : 3)
        .offset(y: revealed ? 0 : (revealFromBottom ? 6 : -6))
        .animation(revealed
                   ? .spring(duration: 0.34, bounce: 0.2).delay(Double(cascadeStep(index)) * 0.018)
                   : .easeOut(duration: 0.08),
                   value: revealed)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
