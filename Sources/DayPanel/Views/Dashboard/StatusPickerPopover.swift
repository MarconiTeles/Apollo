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
                let isSelected = status.status.caseInsensitiveCompare(
                    currentStatusName ?? ""
                ) == .orderedSame
                let statusColor = Color(statusHex: status.displayHex)
                Button {
                    onSelect(status)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isSelected ? statusColor : Editorial.inkMute)
                        Text(status.status.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(statusColor)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                if status.id != statuses.last?.id {
                    Rectangle()
                        .fill(Editorial.ruleSoft)
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                }
            }
        }
        // NSPopover supplies the one native Liquid Glass layer. This view is
        // intentionally content-only: no nested card, blur, border or shadow.
        .frame(width: 172)
        .padding(.vertical, 3)
    }
}
