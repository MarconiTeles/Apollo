import SwiftUI
import UniformTypeIdentifiers

/// Same window-centred placement and bottom in/out movement as task details.
/// A native sheet would override this with the system's top-edge animation.
struct TaskMediaPopupOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var reviewPresenter = TaskReviewQueuePresenter.shared
    let windowSize: CGSize

    private var isPresented: Bool {
        appState.mediaFlowRequest != nil || appState.bulkMediaRequest != nil
            || reviewPresenter.request != nil
    }

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { } // Like a sheet, outside clicks do not dismiss.
                    .onHover { _ in }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        // Preserve delivery when the Finder drop lands outside
                        // the card while it is still animating into position.
                        appState.bulkMediaRequest?.onBackgroundDrop?(providers) ?? false
                    }
                    .transition(.opacity)
            }

            if let request = appState.mediaFlowRequest {
                TaskMediaFlowSheet(dismiss: appState.closeMediaFlow,
                                   store: appState.taskMediaTransfers, request: request)
                    .id(request.id)
                    .transition(TaskMediaPopupMotion.transition(windowSize: windowSize))
            }
            if let request = appState.bulkMediaRequest {
                TaskBulkMediaFlowSheet(store: appState.taskMediaTransfers, request: request,
                                       dismiss: appState.closeBulkMediaFlow)
                    .id(request.id)
                    .transition(TaskMediaPopupMotion.transition(windowSize: windowSize))
            }
            if let request = reviewPresenter.request {
                TaskReviewsFlowSheet(dismiss: reviewPresenter.dismiss, request: request)
                    .id(request.id)
                    .transition(TaskMediaPopupMotion.transition(windowSize: windowSize))
            }
        }
        .animation(isPresented ? TaskMediaPopupMotion.insertion : TaskMediaPopupMotion.removal,
                   value: isPresented)
    }
}

/// Matches TaskDetailOverlay's travel/spring and closeTaskDetail's ease-in.
enum TaskMediaPopupMotion {
    static let insertion = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let removal = Animation.easeIn(duration: 0.30)

    static func transition(windowSize: CGSize) -> AnyTransition {
        // SwiftUI positive Y is down: +travel → 0 enters upward;
        // 0 → +travel exits downward and clears the full window.
        .modifier(active: OffsetYModifier(y: max(windowSize.height, 900)),
                  identity: OffsetYModifier(y: 0))
    }
}
