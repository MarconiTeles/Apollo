import SwiftUI

struct MyTasksFilterToggle: View {
    @Binding var filters: TaskFilters
    @ObservedObject var auth: ClickUpAuthService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Same transparent Liquid Glass capsule as the other toolbar groups
        // (ToolbarGlassGroup): 36pt tall, interactive glass, and in dark mode
        // the 40% black layer that keeps the capsule from reading whitish.
        // The only colour is the native switch, which follows the macOS
        // accent. Explicit Text + hidden toggle label: a window toolbar hides
        // the labels of its controls, and this pill must always show its name.
        GlassEffectContainer {
            HStack(spacing: 8) {
                Text("Minhas tarefas")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Toggle("Minhas tarefas", isOn: Binding(
                    get: { filters.isMine(userId: auth.userId) },
                    set: { filters.setMine($0, userId: auth.userId) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .fixedSize()
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(height: 36)
            .background {
                if colorScheme == .dark {
                    Capsule().fill(Color.black.opacity(0.4))
                }
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .disabled(auth.userId == nil || !auth.isConnected)
        .help("Mostrar apenas tarefas atribuídas a mim nesta lista")
        .accessibilityIdentifier("myTasksToggle")
        .onChange(of: auth.userId) { old, new in
            if old != new, filters.isMine(userId: old) { filters.assigneeIds = [] }
        }
    }
}
