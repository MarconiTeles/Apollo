import SwiftUI

struct MyTasksFilterToggle: View {
    @Binding var filters: TaskFilters
    @ObservedObject var auth: ClickUpAuthService
    var body: some View {
        Toggle("Minhas tarefas", isOn: Binding(
            get: { filters.isMine(userId: auth.userId) },
            set: { filters.setMine($0, userId: auth.userId) }
        ))
        .toggleStyle(.switch)
        .tint(Color(red: 191 / 255, green: 233 / 255, blue: 1))
        .foregroundStyle(.white)
        .controlSize(.small)
        .font(Editorial.sans(12.5, .medium))
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .liquidGlassCapsule(tint: Editorial.accent, tintOpacity: 0.9)
        .accentGlow()
        .disabled(auth.userId == nil || !auth.isConnected)
        .help("Mostrar apenas tarefas atribuídas a mim nesta lista")
        .accessibilityIdentifier("myTasksToggle")
        .onChange(of: auth.userId) { old, new in
            if old != new, filters.isMine(userId: old) { filters.assigneeIds = [] }
        }
    }
}
