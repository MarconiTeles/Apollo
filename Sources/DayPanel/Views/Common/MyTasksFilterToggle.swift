import SwiftUI

struct MyTasksFilterToggle: View {
    @Binding var filters: TaskFilters
    @ObservedObject var auth: ClickUpAuthService

    // Resolve the system accent when drawn so changes in macOS preferences
    // also update the pale switch tint, just as they update the capsule.
    private static let switchTint = Color(nsColor: NSColor(name: nil) { appearance in
        var tint = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            tint = NSColor.controlAccentColor.blended(withFraction: 0.75, of: .white)
                ?? NSColor.controlAccentColor
        }
        return tint
    })

    var body: some View {
        Toggle("Minhas tarefas", isOn: Binding(
            get: { filters.isMine(userId: auth.userId) },
            set: { filters.setMine($0, userId: auth.userId) }
        ))
        .toggleStyle(.switch)
        .tint(Self.switchTint)
        .environment(\.colorScheme, .light)
        .brightness(filters.isMine(userId: auth.userId) ? 0.4 : 0)
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
