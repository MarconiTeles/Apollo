#if DEBUG
import SwiftUI

/// Hosts Apollo's real production root view in an isolated preview state.
/// Select any preview in Xcode's Canvas, enable Selectable mode, and clicking
/// a component navigates to the SwiftUI source that actually renders it.
@MainActor
private struct ApolloPreviewScene: View {
    private let route: SidebarRoute
    private let scheme: ColorScheme
    @StateObject private var appState: AppState
    @StateObject private var updateService = UpdateService()

    init(route: SidebarRoute,
         scheme: ColorScheme = .light,
         scenario: ApolloPreviewScenario = .populated) {
        self.route = route
        self.scheme = scheme
        _appState = StateObject(wrappedValue: AppState.preview(scenario))
    }

    var body: some View {
        ContentView(previewRoute: route)
            .environmentObject(appState)
            .environmentObject(updateService)
            .defaultAppStorage(ApolloPreviewFixtures.defaults)
            .preferredColorScheme(scheme)
            .frame(width: 1440, height: 900)
    }
}

@MainActor
private struct ApolloNotificationsPreviewScene: View {
    private let scheme: ColorScheme
    @StateObject private var appState = AppState.preview(.populated)
    @StateObject private var updateService = UpdateService()

    init(scheme: ColorScheme) {
        self.scheme = scheme
    }

    var body: some View {
        ZStack {
            Editorial.paper.ignoresSafeArea()
            NotificationsCenterView()
                .environmentObject(appState)
                .environmentObject(updateService)
                .environment(\.windowSize, CGSize(width: 620, height: 820))
                .frame(width: 560, height: 760)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        }
        .defaultAppStorage(ApolloPreviewFixtures.defaults)
        .preferredColorScheme(scheme)
        .frame(width: 720, height: 900)
    }
}

// MARK: - Main navigation surfaces

#Preview("01 · Inbox · claro") {
    ApolloPreviewScene(route: .today)
}

#Preview("02 · Tarefas · claro") {
    ApolloPreviewScene(route: .tasks)
}

#Preview("03 · Quadro · claro") {
    ApolloPreviewScene(route: .board)
}

#Preview("04 · Quadro · escuro") {
    ApolloPreviewScene(route: .board, scheme: .dark)
}

#Preview("05 · Comentários · claro") {
    ApolloPreviewScene(route: .assignedComments)
}

// MARK: - States and overlays

#Preview("06 · Tarefas · vazio") {
    ApolloPreviewScene(route: .tasks, scenario: .empty)
}

#Preview("07 · Notificações · claro") {
    ApolloNotificationsPreviewScene(scheme: .light)
}

#Preview("08 · Notificações · escuro") {
    ApolloNotificationsPreviewScene(scheme: .dark)
}
#endif
