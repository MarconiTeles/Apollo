import SwiftUI

/// Task-detail presentation intentionally mirrors `EventDetailOverlay`.
/// Keeping the conditional content, backdrop, full-window travel and explicit
/// dismissal transaction in one observer-backed overlay avoids the computed
/// Binding/FloatingModal path that could insert the task after its transition
/// transaction had already been consumed.
struct TaskDetailOverlay: View {
    @EnvironmentObject var appState: AppState
    let windowSize: CGSize

    var body: some View {
        ZStack {
            if let task = appState.detailTask {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { dismiss() }
                    .onHover { _ in }

                let live = appState.tasksById[task.id] ?? task
                let travel = max(windowSize.height, 900)

                // Keep presentation and carousel replacement in two distinct
                // transition layers. The outer layer exists only while the
                // popup is presented, so opening/closing continues to mirror
                // EventDetailOverlay. Changing `task.id` replaces only the
                // inner sheet and restores the vertical card-carousel motion.
                ZStack {
                    TaskDetailSheet(task: live,
                                    appState: appState,
                                    visibleSubtasks: appState.subtasks(of: live.id),
                                    onClose: dismiss)
                        .equatable()
                        .id(task.id)
                        .transition(detailNavigationTransition)
                }
                .animation(.spring(response: 0.46, dampingFraction: 0.86),
                           value: task.id)
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: OffsetYModifier(y: travel),
                        identity: OffsetYModifier(y: 0)
                    ),
                    removal: .modifier(
                        active: OffsetYModifier(y: travel),
                        identity: OffsetYModifier(y: 0)
                    )
                ))
            }
        }
        // Animate only the nil/non-nil presentation boundary here. Using the
        // task id as this value made carousel replacements inherit the popup's
        // full-window travel and effectively erased their own transition.
        // `closeTaskDetail` supplies the matching explicit removal transaction.
        .animation(.spring(response: 0.34, dampingFraction: 0.86),
                   value: appState.detailTask != nil)
    }

    /// A next task rises from below while the current task exits upward;
    /// previous performs the exact inverse. `.identity` is important on the
    /// initial presentation so this layer never competes with popup in/out.
    private var detailNavigationTransition: AnyTransition {
        switch appState.detailNavigationDirection {
        case .next:
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        case .previous:
            return .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .bottom).combined(with: .opacity)
            )
        case .none:
            return .identity
        }
    }

    private func dismiss() {
        appState.closeTaskDetail()
    }
}
