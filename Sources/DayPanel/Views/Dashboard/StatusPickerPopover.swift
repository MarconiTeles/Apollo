import SwiftUI

/// Canonical status-selection popover used everywhere a user picks a
/// ClickUp status. Renders the workspace's available statuses as a
/// vertical list with the canonical pill colour for each label and a
/// checkmark indicating the current selection — same look across the
/// task row, task detail (inline + popup), and the create-task form.
///
/// The component is intentionally agnostic about *what* changes when a
/// status is picked — callers pass an `onSelect(CUStatus)` closure
/// that receives the chosen status and decides whether to:
///   - mutate AppState (TaskRowView / TaskDetailView edit flows), or
///   - just update local @State (CreateTaskSheet new-task flow).
struct StatusPickerPopover: View {
    let statuses: [CUStatus]
    let currentStatusName: String?
    let onSelect: (CUStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(statuses) { status in
                let isSelected  = status.status == currentStatusName
                let statusColor = Color(hex: status.displayHex)
                Button {
                    onSelect(status)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(isSelected ? statusColor : Color(NSColor.tertiaryLabelColor))
                        Text(status.status.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(statusColor)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if status.id != statuses.last?.id {
                    Rectangle().fill(.separator.opacity(0.3)).frame(height: 0.5)
                }
            }
        }
        .frame(minWidth: 180)
        .padding(.vertical, 4)
    }
}
