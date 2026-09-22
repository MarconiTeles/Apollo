#if DEBUG
import SwiftUI

public enum ApolloStudioRoute: String, CaseIterable, Identifiable, Codable, Sendable {
    case inbox, tasks, board, comments, notifications
    case taskDetail, eventDetail, settings, onboarding, ai
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .tasks: "Tarefas"
        case .board: "Quadros"
        case .comments: "Comentários"
        case .notifications: "Notificações"
        case .taskDetail: "Detalhe da tarefa"
        case .eventDetail: "Detalhe do evento"
        case .settings: "Configurações"
        case .onboarding: "Onboarding"
        case .ai: "Apollo IA"
        }
    }

    var usesApplicationShell: Bool {
        switch self {
        case .inbox, .tasks, .board, .comments: true
        case .notifications, .taskDetail, .eventDetail, .settings, .onboarding, .ai: false
        }
    }
}

public enum ApolloStudioScenario: String, CaseIterable, Identifiable, Codable, Sendable {
    case populated, empty, loading, error
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .populated: "Carregado"
        case .empty: "Vazio"
        case .loading: "Carregando"
        case .error: "Erro"
        }
    }
}

public enum ApolloStudioAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case system, light, dark
    public var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Public, deterministic entry point used by Apollo Studio and Xcode Canvas.
/// It is the production Apollo hierarchy backed by local fixtures, not a
/// redrawn approximation.
@MainActor
public struct ApolloStudioRootView: View {
    public let route: ApolloStudioRoute
    public let scenario: ApolloStudioScenario
    public let appearance: ApolloStudioAppearance
    @ObservedObject private var session: ApolloStudioSession
    @StateObject private var appState: AppState
    @StateObject private var updateService = UpdateService()

    public init(route: ApolloStudioRoute,
                scenario: ApolloStudioScenario = .populated,
                appearance: ApolloStudioAppearance = .system,
                session: ApolloStudioSession) {
        ApolloRuntimeEnvironment.assertStudioIsolation()
        self.route = route
        self.scenario = scenario
        self.appearance = appearance
        self.session = session
        let previewState = AppState.preview(scenario.previewScenario)
        self._appState = StateObject(wrappedValue: previewState)
    }

    public var body: some View {
        Group { studioSurface }
        .environmentObject(appState)
        .environmentObject(updateService)
        .defaultAppStorage(ApolloPreviewFixtures.defaults)
        .preferredColorScheme(appearance.colorScheme)
        .apolloStudioNode("app.root",
                          title: "Apollo",
                          kind: .app,
                          properties: [
                            .init(kind: .width, title: "Largura"),
                            .init(kind: .height, title: "Altura"),
                          ])
        .collectApolloStudioNodes(into: session)
    }

    @ViewBuilder
    private var studioSurface: some View {
        if route.usesApplicationShell {
            ContentView(previewRoute: route.sidebarRoute)
        } else {
            ZStack {
                Editorial.paper.ignoresSafeArea()
                isolatedSurface
            }
        }
    }

    @ViewBuilder
    private var isolatedSurface: some View {
        switch route {
        case .notifications:
            NotificationsCenterView()
                .environment(\.windowSize, CGSize(width: 620, height: 820))
                .frame(width: 560, height: 760)
                .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                .apolloStudioNode("notifications.panel",
                                  title: "Popup de notificações",
                                  kind: .popover,
                                  parent: "app.root")
        case .taskDetail:
            if let task = appState.tasks.first {
                TaskDetailSheet(task: task,
                                appState: appState,
                                visibleSubtasks: appState.subtasks(of: task.id))
                    .environment(\.windowSize, CGSize(width: 1440, height: 900))
                    .apolloStudioNode("task-detail.panel",
                                      title: "Detalhe da tarefa",
                                      kind: .popover,
                                      parent: "app.root")
            } else {
                studioEmptyState("Nenhuma tarefa na fixture", symbol: "checklist")
            }
        case .eventDetail:
            if let event = appState.events.first {
                EventDetailView(event: event)
                    .environment(\.windowSize, CGSize(width: 1440, height: 900))
                    .apolloStudioNode("event-detail.panel",
                                      title: "Detalhe do evento",
                                      kind: .popover,
                                      parent: "app.root")
            } else {
                studioEmptyState("Nenhum evento na fixture", symbol: "calendar")
            }
        case .settings:
            SettingsView()
                .environment(\.windowSize, CGSize(width: 1440, height: 900))
                .apolloStudioNode("settings.panel",
                                  title: "Configurações",
                                  kind: .page,
                                  parent: "app.root")
        case .onboarding:
            OnboardingView()
                .apolloStudioNode("onboarding.panel",
                                  title: "Onboarding",
                                  kind: .page,
                                  parent: "app.root")
        case .ai:
            AIAgentChatView()
                .frame(width: 760, height: 760)
                .apolloStudioNode("ai.panel",
                                  title: "Apollo IA",
                                  kind: .popover,
                                  parent: "app.root")
        case .inbox, .tasks, .board, .comments:
            EmptyView()
        }
    }

    private func studioEmptyState(_ title: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .apolloStudioNode("fixture.empty",
                              title: title,
                              kind: .overlay,
                              parent: "app.root")
    }
}

private extension ApolloStudioScenario {
    var previewScenario: ApolloPreviewScenario {
        switch self {
        case .populated: .populated
        case .empty: .empty
        case .loading: .loading
        case .error: .error
        }
    }
}

private extension ApolloStudioRoute {
    var sidebarRoute: SidebarRoute {
        switch self {
        case .inbox: .today
        case .tasks: .tasks
        case .board: .board
        case .comments: .assignedComments
        case .notifications, .taskDetail, .eventDetail, .settings, .onboarding, .ai: .today
        }
    }
}
#endif
