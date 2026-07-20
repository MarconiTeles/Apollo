import Foundation
import ReviewKit
import SwiftUI

/// Chooser shown only when one task has more than one actionable review.
/// A single review keeps the faster direct-open behavior in the AppKit row.
struct TaskReviewsFlowSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TaskReviewUpdateStore.shared

    let request: TaskReviewQueueRequest

    @State private var concludingIds: Set<String> = []
    @State private var approvalSavingIds: Set<String> = []
    @State private var approvalOverrides: [String: Bool] = [:]
    @State private var errorMessage: String?

    private let headerHeight: CGFloat = 66
    private let footerHeight: CGFloat = 68

    private var outerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Editorial.popupRadius(9), style: .continuous)
    }

    private var headerShape: UnevenRoundedRectangle {
        let radius = Editorial.popupRadius(9)
        return UnevenRoundedRectangle(topLeadingRadius: radius,
                                      bottomLeadingRadius: 0,
                                      bottomTrailingRadius: 0,
                                      topTrailingRadius: radius,
                                      style: .continuous)
    }

    private var footerShape: UnevenRoundedRectangle {
        let radius = Editorial.popupRadius(9)
        return UnevenRoundedRectangle(topLeadingRadius: 0,
                                      bottomLeadingRadius: radius,
                                      bottomTrailingRadius: radius,
                                      topTrailingRadius: 0,
                                      style: .continuous)
    }

    private var updates: [TaskReviewUpdateStore.Update] {
        store.updates(for: request.task.id)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    HStack {
                        Text("VÍDEOS PARA REVISAR")
                            .font(Editorial.sans(10.5, .semibold))
                            .tracking(1.35)
                            .foregroundStyle(Editorial.inkMute)
                        Spacer()
                        Text("\(updates.count)")
                            .font(Editorial.sans(10.5, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Editorial.inkFaint)
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                    ForEach(updates, id: \.activeAtt) { update in
                        reviewRow(update)
                            .transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
            .padding(.top, headerHeight)
            .padding(.bottom, footerHeight)

            if let errorMessage {
                Text(errorMessage)
                    .font(Editorial.sans(11.5, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Editorial.accent))
                    .shadow(color: Editorial.accent.opacity(0.22), radius: 7, y: 3)
                    .padding(.top, headerHeight + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
            }

            header
                .frame(height: headerHeight)
                .frame(maxWidth: .infinity)
                .liquidGlass(in: headerShape, tint: Editorial.ink,
                             tintOpacity: 0.01, interactive: false)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                }
                .zIndex(20)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack {
                    Text("A conclusão só é aceita após a review estar aprovada no Apollo Review.")
                        .font(Editorial.sans(10.5))
                        .foregroundStyle(Editorial.inkMute)
                    Spacer()
                    Button("FECHAR") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(Editorial.sans(10.5, .semibold))
                    .foregroundStyle(Editorial.inkSoft)
                    .focusable(false)
                }
                .padding(.horizontal, 22)
                .frame(height: footerHeight)
                .frame(maxWidth: .infinity)
                .liquidGlass(in: footerShape, tint: Editorial.ink,
                             tintOpacity: 0.01, interactive: false)
                .overlay(alignment: .top) {
                    Rectangle().fill(Editorial.rule.opacity(0.6)).frame(height: 1)
                }
            }
            .zIndex(20)
        }
        .frame(width: 720, height: 520)
        .solidPopupSurface(in: outerShape)
        .onAppear {
            appState.swiftUIPopupOpen = true
        }
        .onDisappear { appState.swiftUIPopupOpen = false }
        .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86),
                   value: updates.map(\.activeAtt))
        .onChange(of: updates.count) { _, count in
            if count == 0 {
                Task {
                    try? await Task.sleep(for: .milliseconds(380))
                    dismiss()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Editorial.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Editorial.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text("Reviews pendentes")
                    .font(Editorial.sans(16, .semibold))
                    .foregroundStyle(Editorial.ink)
                Text(request.task.title)
                    .font(Editorial.sans(11.5))
                    .foregroundStyle(Editorial.inkSoft)
                    .lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverGlass()
            .focusable(false)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Fechar")
        }
        .padding(.horizontal, 22)
    }

    private func reviewRow(_ update: TaskReviewUpdateStore.Update) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Editorial.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Editorial.accentSoft))

            VStack(alignment: .leading, spacing: 4) {
                Text(update.displayTitle)
                    .font(Editorial.sans(12.5, .semibold))
                    .foregroundStyle(Editorial.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let version = update.meta.evaluatedVersionId
                        ?? update.meta.currentVersionId, !version.isEmpty {
                        Text(version.uppercased())
                        Text("·")
                    }
                    Text(update.meta.isApproved ? "APROVADA" : "EM REVISÃO")
                    Text("·")
                    Text("\(update.meta.commentCount) comentário\(update.meta.commentCount == 1 ? "" : "s")")
                }
                .font(Editorial.sans(10.5, .medium))
                .foregroundStyle(update.meta.isApproved
                                 ? Color.green.opacity(0.85) : Editorial.inkMute)
            }

            Spacer(minLength: 14)

            TaskMediaCapsuleButton(label: "ABRIR REVIEW", primary: true,
                                   disabled: isBusy(update), badge: nil) {
                open(update)
            }

            approvalControl(update)

            if concludingIds.contains(update.activeAtt) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 96, height: 34)
            } else {
                TaskMediaCapsuleButton(label: "CONCLUIR", primary: false,
                                       disabled: isBusy(update) || !isApproved(update),
                                       badge: nil) {
                    conclude(update)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background {
            RoundedRectangle(cornerRadius: Editorial.popupRadius(5), style: .continuous)
                .fill(Editorial.card)
                .overlay {
                    RoundedRectangle(cornerRadius: Editorial.popupRadius(5), style: .continuous)
                        .strokeBorder(Editorial.rule.opacity(0.72), lineWidth: 1)
                }
        }
    }

    private func approvalControl(_ update: TaskReviewUpdateStore.Update) -> some View {
        HStack(spacing: 7) {
            Text("Aprovar")
                .font(Editorial.sans(10.5, .medium))
                .foregroundStyle(Editorial.inkSoft)

            if approvalSavingIds.contains(update.activeAtt) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 34, height: 24)
            } else {
                Toggle("Aprovar", isOn: Binding(
                    get: { isApproved(update) },
                    set: { setApproved($0, for: update) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Editorial.accent)
                .focusable(false)
                .disabled(!concludingIds.isEmpty)
                .accessibilityHint("Altera a aprovação sem concluir a review")
            }
        }
        .frame(width: 92, alignment: .trailing)
    }

    private func isApproved(_ update: TaskReviewUpdateStore.Update) -> Bool {
        approvalOverrides[update.activeAtt] ?? update.meta.isApproved
    }

    private func isBusy(_ update: TaskReviewUpdateStore.Update) -> Bool {
        concludingIds.contains(update.activeAtt)
            || approvalSavingIds.contains(update.activeAtt)
    }

    private func setApproved(_ approved: Bool,
                             for update: TaskReviewUpdateStore.Update) {
        guard !isBusy(update), approved != isApproved(update) else { return }
        approvalOverrides[update.activeAtt] = approved
        approvalSavingIds.insert(update.activeAtt)
        errorMessage = nil

        Task { @MainActor in
            let failure = await persistApproval(approved, for: update)
            approvalSavingIds.remove(update.activeAtt)
            approvalOverrides.removeValue(forKey: update.activeAtt)
            if let failure {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    errorMessage = failure
                }
            }
        }
    }

    @MainActor
    private func persistApproval(_ approved: Bool,
                                 for update: TaskReviewUpdateStore.Update) async -> String? {
        let context = ReviewSessionContext(params: params(for: update),
                                           markSeenOnLoad: false)
        guard let currentPayload = await context.load(),
              let updatedPayload = ReviewBackend.payload(
                currentPayload, settingApproved: approved
              ) else {
            return "não foi possível carregar a review"
        }
        guard await context.save(payloadData: updatedPayload) else {
            return "a aprovação não foi salva"
        }
        guard let meta = await context.versionMeta(payloadData: updatedPayload),
              meta.isApproved == approved else {
            return "o servidor não confirmou a aprovação"
        }
        guard store.refreshPendingMetadata(
            taskId: update.taskId,
            activeAtt: update.activeAtt,
            meta: meta
        ) else {
            return "a review mudou; atualize a lista e tente novamente"
        }
        return nil
    }

    private func params(for update: TaskReviewUpdateStore.Update) -> OpenReviewParams {
        let actorId = appState.clickUpAuthService.userId ?? 0
        let actorName = appState.availableMembers
            .first { $0.id == actorId }?.username ?? "Revisor"
        return ReviewLink.params(attachment: update.attachment,
                                 taskId: request.task.id,
                                 listId: request.task.listId,
                                 uploaderId: update.attachment.uploaderId,
                                 actorId: actorId,
                                 actorName: actorName,
                                 reviewId: update.meta.reviewId,
                                 versionId: update.meta.evaluatedVersionId
                                    ?? update.meta.currentVersionId)
    }

    private func open(_ update: TaskReviewUpdateStore.Update) {
        let reviewParams = params(for: update)
        let acknowledgement = ReviewCompletionAcknowledgement(
            taskId: request.task.id,
            activeAtt: update.activeAtt
        )
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            ReviewPresenter.shared.present(
                reviewParams,
                completionAcknowledgement: acknowledgement
            )
        }
    }

    private func conclude(_ update: TaskReviewUpdateStore.Update) {
        guard concludingIds.isEmpty else { return }
        concludingIds.insert(update.activeAtt)
        errorMessage = nil

        Task { @MainActor in
            let failure = await concludeApprovedReview(update)
            concludingIds.remove(update.activeAtt)
            if let failure {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    errorMessage = failure
                }
            }
        }
    }

    @MainActor
    private func concludeApprovedReview(_ update: TaskReviewUpdateStore.Update) async -> String? {
        let context = ReviewSessionContext(params: params(for: update),
                                           markSeenOnLoad: false)
        guard let data = await context.load() else {
            return "não foi possível carregar a review"
        }
        let activeAtt = context.activeAtt ?? update.activeAtt
        guard let before = await context.versionMeta(payloadData: data),
              before.isApproved, ReviewBackend.payloadIsApproved(data) else {
            return "ative APROVADO dentro da review antes de concluir"
        }
        guard let meta = await context.concludeAndConfirm(payloadData: data),
              meta.isApprovedAndConcluded else {
            return "o servidor ainda não confirmou a conclusão"
        }
        guard store.acknowledgeConfirmedCompletion(
            taskId: update.taskId,
            pendingActiveAtt: update.activeAtt,
            confirmedActiveAtt: activeAtt,
            meta: meta
        ) else { return "a review mudou; atualize a lista e tente novamente" }
        return nil
    }
}
