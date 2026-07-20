import Foundation
import ReviewKit

/// Fixa a identidade da sessão de review durante UMA abertura do sheet.
/// `load()` escolhe/reconcilia a chave (via `ReviewBackend.openSession`) e a
/// partir daí TODO acesso — autosave, flush da conclusão, markSeen, watcher —
/// usa exatamente a mesma chave. Proíbe o bug de carregar de uma chave e
/// salvar noutra (era o que dividia web × nativo em dois documentos KV).
final class ReviewSessionContext {
    private let params: OpenReviewParams
    private let key: ReviewBackend.SessionKey
    private let markSeenOnLoad: Bool

    /// Chave ativa após o load (nil antes). O espelho legado recebe dual-write
    /// enquanto existir, para links antigos `?att=<hash>` seguirem atuais.
    private(set) var activeAtt: String?
    private(set) var mirrorAtt: String?

    init(params: OpenReviewParams, markSeenOnLoad: Bool = false) {
        self.params = params
        self.markSeenOnLoad = markSeenOnLoad
        // `attachmentId` changes for every V1/V2/V3 file. `reviewId` is the
        // permanent lineage key and therefore must own load/save/conclusion.
        // Falling back keeps old, non-versioned review links compatible.
        self.key = ReviewBackend.sessionKey(attachmentId: params.reviewId ?? params.attachmentId,
                                            mediaUrl: params.mediaUrl)
    }

    /// liveLoad do ReviewView. Também registra a sessão no watcher. Fluxos
    /// comuns marcam como vista na mesma chave; o VER REVIEW da lista adia
    /// esse consumo até `Concluir review -> Fechar`.
    func load() async -> Data? {
        guard var opened = await ReviewBackend.openSession(
            key: key, mediaUrl: params.mediaUrl, ext: params.ext,
            title: params.mediaTitle, taskId: params.taskId,
            listId: params.listId, uploaderId: params.uploaderId)
        else {
            Log.error("Review: openSession falhou (canônica=\(key.canonical ?? "-") legada=\(key.legacy)) — sheet sem sessão ativa")
            return nil
        }

        // Version registration is a migration/create operation, never a side
        // effect of selecting another existing version. Inspect the resolved
        // document first and register only a genuinely absent version.
        let requestedVersionId = params.versionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let requestedVersionId, !requestedVersionId.isEmpty,
           !ReviewBackend.containsVersion(in: opened.data,
                                          versionId: requestedVersionId) {
            guard let mediaURL = URL(string: params.mediaUrl),
                  await ReviewBackend.registerVersion(
                    reviewId: opened.att,
                    versionId: requestedVersionId,
                    attachmentId: params.attachmentId,
                    mediaURL: mediaURL,
                    mediaTitle: params.mediaTitle,
                    ext: params.ext,
                    taskId: params.taskId,
                    uploaderId: params.uploaderId
                  ),
                  let reopened = await ReviewBackend.openSession(
                    key: key, mediaUrl: params.mediaUrl, ext: params.ext,
                    title: params.mediaTitle, taskId: params.taskId,
                    listId: params.listId, uploaderId: params.uploaderId
                  )
            else {
                Log.error("Review: não foi possível registrar \(requestedVersionId) antes de abrir")
                return nil
            }
            opened = reopened
        }

        activeAtt = opened.att
        mirrorAtt = opened.mirror
        let resolvedAtt = opened.att
        let meta: ReviewBackend.Meta?
        if let requestedVersionId, !requestedVersionId.isEmpty {
            meta = ReviewBackend.versionMeta(in: opened.data,
                                             versionId: requestedVersionId)
        } else {
            meta = await ReviewBackend.meta(att: opened.att)
        }
        let updatedAt = meta?.updatedAt

        // A valid exact-version read is authoritative. It repairs latches from
        // builds that copied V1 comments/conclusion into the latest V2/V3 row,
        // while a network error deliberately performs no destructive action.
        if let meta {
            let attachment = CUTask.Attachment(
                id: params.attachmentId,
                title: params.mediaTitle,
                url: params.mediaUrl,
                ext: params.ext,
                sizeString: nil,
                totalComments: meta.commentCount,
                resolvedComments: nil,
                uploaderId: params.uploaderId
            )
            await MainActor.run {
                TaskReviewUpdateStore.shared.reconcileOpenedVersion(
                    taskId: params.taskId,
                    activeAtt: resolvedAtt,
                    attachment: attachment,
                    meta: meta
                )
            }
        }
        if markSeenOnLoad {
            let observationKey = ReviewBackend.observationKey(
                att: resolvedAtt, versionId: requestedVersionId
            )
            ReviewBackend.markSeen(att: observationKey, updatedAt: updatedAt,
                                   commentCount: meta?.commentCount,
                                   status: meta?.status)
        }
        ReviewWatcher.shared.register(
            att: resolvedAtt, mediaUrl: params.mediaUrl, ext: params.ext,
            taskId: params.taskId, title: params.mediaTitle,
            uploaderId: params.uploaderId, tintHex: nil,
            currentUpdatedAt: updatedAt, versionId: requestedVersionId)
        return opened.data
    }

    /// liveSave (autosave) e flush final — sempre na chave aberta. Fallback
    /// para o caminho por-payload só se salvar antes de qualquer load (não
    /// acontece no fluxo do sheet, mas não pode perder dado se acontecer).
    @discardableResult
    func save(payloadData: Data) async -> Bool {
        if let att = activeAtt {
            return await ReviewBackend.save(att: att, mirror: mirrorAtt,
                                            payloadData: payloadData)
        }
        // No fluxo do sheet este fallback NUNCA deve rodar: significa que o
        // autosave está desacoplado da sessão aberta e escreveria numa chave
        // derivada do payload (potencialmente uma duplicata órfã).
        Log.error("Review: save sem sessão aberta — fallback por payload")
        return await ReviewBackend.save(payloadData: payloadData)
    }

    /// Explicit conclusion is different from autosave. It records the final
    /// action on the server without conflating it with the approval toggle.
    @discardableResult
    func conclude(payloadData: Data) async -> Bool {
        if let att = activeAtt {
            return await ReviewBackend.conclude(att: att, mirror: mirrorAtt,
                                                payloadData: payloadData)
        }
        // Ver comentário no save(): uma conclusão sem sessão aberta gravaria
        // o estado final numa chave órfã e a confirmação por versão exata
        // (que exige `activeAtt`) reprovaria em seguida.
        Log.error("Review: conclude sem sessão aberta — fallback por payload")
        return await ReviewBackend.conclude(payloadData: payloadData)
    }

    /// Persists an explicit conclusion and then proves that the exact submitted
    /// media version contains the submitted status plus `concludedAt`.
    /// A successful HTTP response alone is not enough: the review lineage may
    /// currently project a different V1/V2/V3 state at its root.
    func concludeAndConfirm(payloadData: Data) async -> ReviewBackend.Meta? {
        guard let versionId = ReviewBackend.payloadVersionId(payloadData),
              let expectedStatus = ReviewBackend.payloadStatus(payloadData)
        else {
            Log.error("Review: conclusão abortada — payload sem versionId/status")
            return nil
        }
        guard await conclude(payloadData: payloadData) else {
            Log.error("Review: /session/conclude falhou (att=\(activeAtt ?? "nil") versão=\(versionId))")
            return nil
        }

        for delayNanoseconds in [UInt64(0), 150_000_000, 350_000_000] {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let meta = await versionMeta(versionId: versionId) else { continue }
            let persistedStatus = meta.status?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if meta.isConcluded, persistedStatus == expectedStatus {
                return meta
            }
        }
        Log.error("Review: servidor não confirmou a versão concluída (att=\(activeAtt ?? "nil") versão=\(versionId) esperado=\(expectedStatus))")
        return nil
    }

    /// Fresh, version-specific read used by the inline approval control and the
    /// conclusion flow. It never interprets the lineage root as another
    /// version's state.
    func versionMeta(payloadData: Data) async -> ReviewBackend.Meta? {
        guard let versionId = ReviewBackend.payloadVersionId(payloadData) else { return nil }
        return await versionMeta(versionId: versionId)
    }

    private func versionMeta(versionId: String) async -> ReviewBackend.Meta? {
        guard let att = activeAtt,
              let data = await ReviewBackend.resolve(
                att: att,
                mediaUrl: params.mediaUrl,
                ext: params.ext,
                title: params.mediaTitle,
                taskId: params.taskId,
                listId: params.listId,
                uploaderId: params.uploaderId
              )
        else { return nil }
        return ReviewBackend.versionMeta(in: data, versionId: versionId)
    }
}
