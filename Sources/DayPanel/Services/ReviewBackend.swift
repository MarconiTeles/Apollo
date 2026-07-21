import Foundation

/// Client for the single live review link's backend (a Cloudflare Worker over
/// KV). Mirrors the web's `src/contract/session.ts`: a review is ONE JSON blob
/// per attachment, keyed by `att`. The native Apollo review opens/creates and
/// modifies the SAME blob as the web — so both are the same review behind the
/// same `?att=` link.
///
/// ## Identidade da sessão (fix 17/jul/2026)
/// O web (novo fluxo rápido de mídia) abre por `?att=<id real do anexo>`;
/// o nativo historicamente derivava a chave só da URL (`stableId(mediaUrl)`).
/// Sem alias no Worker, isso divide um mesmo vídeo em DOIS documentos KV.
/// A identidade agora é explícita (`SessionKey`: canônica = id real do anexo,
/// legada = hash da URL) e a abertura escolhe/reconcilia a sessão existente —
/// nunca recalculando a chave silenciosamente em load/save/badge/watcher.
///
/// Type-agnostic on purpose: ReviewKit's `ReviewComment` is internal to that
/// module, so we pass JSON through (the worker + ReviewKit own the shape) and
/// never decode comments here.
enum ReviewBackend {
    /// Same Worker the web talks to. Endpoints are public (no auth, CORS open).
    static let base = "https://apollo-review-proxy.marconimpn.workers.dev"

    // ── Identidade ───────────────────────────────────────────────────────────

    /// As duas chaves KV possíveis de um mesmo anexo.
    struct SessionKey: Equatable {
        /// Id real do anexo no ClickUp (o `att` que o web usa no fluxo novo).
        /// nil quando o chamador não tem o id (ou ele coincide com a legada).
        let canonical: String?
        /// Hash FNV-1a da mediaUrl (chave histórica do nativo e dos links
        /// antigos do `postFileComment`).
        let legacy: String

        /// Onde criar uma sessão nova quando nenhuma existe.
        var creationTarget: String { canonical ?? legacy }
    }

    static func sessionKey(attachmentId: String?, mediaUrl: String) -> SessionKey {
        let legacy = AppState.stableId(mediaUrl)
        let id = attachmentId?.trimmingCharacters(in: .whitespaces) ?? ""
        return SessionKey(canonical: (id.isEmpty || id == legacy) ? nil : id,
                          legacy: legacy)
    }

    /// Legacy identity (hash-da-URL). Mantida para links antigos e para os
    /// pontos que ainda não conhecem o id real do anexo.
    static func att(forMediaUrl url: String) -> String { AppState.stableId(url) }

    // ── /session/meta (leitura barata, NUNCA cria sessão) ────────────────────

    struct Meta {
        let exists: Bool
        let updatedAt: String?
        let status: String?
        let commentCount: Int
        let reviewId: String?
        let currentVersionId: String?
        let mediaTitle: String?

        /// The concrete media version whose state was evaluated. `/session/meta`
        /// describes only the lineage's current projection, so this stays nil
        /// there. Version-sensitive confirmation fills it from
        /// `versionStates[versionId]` returned by `/session/resolve`.
        let evaluatedVersionId: String?

        /// Timestamp written only by the explicit "Concluir review" action.
        /// Approval is a separate state: only both together make the review
        /// final from Apollo's point of view.
        let concludedAt: String?

        init(exists: Bool, updatedAt: String?, status: String?,
             commentCount: Int, concludedAt: String? = nil,
             reviewId: String? = nil, currentVersionId: String? = nil,
             mediaTitle: String? = nil, evaluatedVersionId: String? = nil) {
            self.exists = exists
            self.updatedAt = updatedAt
            self.status = status
            self.commentCount = commentCount
            self.concludedAt = concludedAt
            self.reviewId = reviewId
            self.currentVersionId = currentVersionId
            self.mediaTitle = mediaTitle
            self.evaluatedVersionId = evaluatedVersionId
        }

        var isApproved: Bool {
            status?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "approved"
        }

        var isApprovedAndConcluded: Bool {
            isApproved && isConcluded
        }

        var isConcluded: Bool {
            !(concludedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
        }

        /// Evidence that a person actually interacted with this review.
        ///
        /// `updatedAt` alone is not evidence: creating the session, registering
        /// a replacement version and other media-lifecycle operations also
        /// advance that timestamp. A pristine `in_review` session must never
        /// produce VER REVIEW.
        var hasReviewerActivityEvidence: Bool {
            if commentCount > 0 { return true }
            if !(concludedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true) { return true }
            let normalizedStatus = status?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedStatus != nil
                && normalizedStatus != ""
                && normalizedStatus != "in_review"
        }
    }

    static func meta(att: String, versionId: String? = nil) async -> Meta? {
        // One KV read per reviewId#versionId per window: the row probe, the
        // background watcher and the flow sheet all share this cache, so
        // duplicated pollers can no longer drain the Worker's daily KV quota.
        let cacheKey = observationKey(att: att, versionId: versionId)
        if let cached = readGate.cachedMeta(for: cacheKey) { return cached }
        // While the backend is failing (429/5xx/quota/transport) reads back
        // off exponentially instead of hammering it. Writes are not gated:
        // a user-initiated save must be able to discover recovery first.
        guard !readGate.isCoolingDown else { return nil }
        var body: [String: Any] = ["attachmentId": att]
        if let versionId = normalizedIdentifier(versionId) {
            body["versionId"] = versionId
        }
        guard let data = await post("/session/meta", body) else {
            readGate.recordReadFailure()
            return nil
        }
        readGate.recordReadSuccess()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let evaluatedVersionId = normalizedIdentifier(
            obj["evaluatedVersionId"] as? String
        )
        // An older Worker ignores `versionId` and returns the lineage root.
        // Refuse that answer: root activity must never be relabelled as the
        // requested V2/V3 by the client.
        if let requested = normalizedIdentifier(versionId),
           evaluatedVersionId != requested {
            return nil
        }
        let meta = Meta(
            exists: (obj["exists"] as? Bool) ?? false,
            updatedAt: obj["updatedAt"] as? String,
            status: obj["status"] as? String,
            commentCount: (obj["commentCount"] as? Int) ?? 0,
            concludedAt: obj["concludedAt"] as? String,
            reviewId: obj["reviewId"] as? String,
            currentVersionId: obj["currentVersionId"] as? String,
            mediaTitle: obj["mediaTitle"] as? String,
            evaluatedVersionId: evaluatedVersionId
        )
        readGate.cache(meta, for: cacheKey)
        return meta
    }

    static func meta(forMediaUrl mediaUrl: String) async -> Meta? {
        await meta(att: att(forMediaUrl: mediaUrl))
    }

    /// UserDefaults key for one exact media version inside a stable review
    /// lineage. V1 and V2 may share the same `att`, but their seen/observed
    /// baselines must never share storage.
    static func observationKey(att: String, versionId: String?) -> String {
        guard let versionId = normalizedIdentifier(versionId) else { return att }
        return "\(att)#\(versionId)"
    }

    /// Badge/watcher: qual das duas chaves está viva, sem criar nada.
    /// Canônica ganha quando as duas existem (é para onde a abertura migra).
    /// Nenhuma viva → aponta para o alvo de criação com exists=false.
    static func activeMeta(key: SessionKey) async -> (att: String, meta: Meta) {
        if let canon = key.canonical {
            let mc = await meta(att: canon)
            if mc?.exists == true { return (canon, mc!) }
            let ml = await meta(att: key.legacy)
            if ml?.exists == true { return (key.legacy, ml!) }
            return (canon, mc ?? Meta(exists: false, updatedAt: nil,
                                     status: nil, commentCount: 0))
        }
        let ml = await meta(att: key.legacy)
        return (key.legacy, ml ?? Meta(exists: false, updatedAt: nil,
                                     status: nil, commentCount: 0))
    }

    // ── Abertura da sessão (escolha + reconciliação) ─────────────────────────

    /// Sessão efetivamente aberta: `att` é a chave que TODOS os consumidores
    /// (load/save/conclusão/badge/watcher) devem usar até o sheet fechar;
    /// `mirror` é a chave legada a receber dual-write enquanto ela existir
    /// (mantém links antigos `?att=<hash>` convergentes).
    struct OpenedSession {
        let att: String
        let mirror: String?
        let data: Data
    }

    /// Load-or-create escolhendo a sessão certa:
    ///  1. as duas chaves são consultadas via `meta` (não cria);
    ///  2. existe uma → o Worker copia o documento versionado inteiro para a
    ///     chave canônica, preservando a legada como espelho;
    ///  3. existem as duas → o Worker reconcilia cada `versionState`
    ///     separadamente, sem jamais unir comentários de V3 com V4;
    ///  4. nenhuma → cria SÓ a canônica (ou a legada, sem id real).
    static func openSession(key: SessionKey, mediaUrl: String, ext: String,
                            title: String, taskId: String, listId: String?,
                            uploaderId: Int?) async -> OpenedSession? {
        func fetch(_ att: String) async -> Data? {
            await resolve(att: att, mediaUrl: mediaUrl, ext: ext, title: title,
                          taskId: taskId, listId: listId, uploaderId: uploaderId)
        }

        // O Worker pode REDIRECIONAR um resolve de id físico/hash para a
        // review estável da linhagem (links antigos do ClickUp). O documento
        // devolvido carrega a identidade verdadeira — adotá-la garante que
        // autosave/conclusão/confirm usem a MESMA sessão que foi aberta,
        // nunca uma chave órfã derivada do pedido.
        func adoptedAtt(_ data: Data, requested: String) -> String {
            guard let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let id = (obj["reviewId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty
            else { return requested }
            return id
        }

        guard let canon = key.canonical else {
            // Sem id real → mundo antigo, uma chave só.
            guard let d = await fetch(key.legacy) else { return nil }
            return OpenedSession(att: adoptedAtt(d, requested: key.legacy),
                                 mirror: nil, data: d)
        }

        let mc = await meta(att: canon)
        let ml = await meta(att: key.legacy)
        let canonExists  = mc?.exists == true
        let legacyExists = ml?.exists == true

        switch (canonExists, legacyExists) {
        case (true, false):
            guard let d = await fetch(canon) else { return nil }
            return OpenedSession(att: adoptedAtt(d, requested: canon),
                                 mirror: nil, data: d)

        case (false, false):
            guard let d = await fetch(canon) else { return nil }
            return OpenedSession(att: adoptedAtt(d, requested: canon),
                                 mirror: nil, data: d)

        case (false, true):
            // Migração integral. Se o Worker ativo ainda não conhecer a rota,
            // mantenha o documento legado como origem; nunca tente reproduzi-lo
            // com o payload raiz, pois isso achataria o histórico de versões.
            if let d = await reconcile(canonical: canon, legacy: key.legacy) {
                return OpenedSession(att: canon, mirror: key.legacy, data: d)
            }
            guard let d = await fetch(key.legacy) else { return nil }
            return OpenedSession(att: adoptedAtt(d, requested: key.legacy),
                                 mirror: nil, data: d)

        case (true, true):
            // Divergência real: o Worker escolhe o estado mais novo DE CADA
            // versão e devolve o documento completo. Um fallback lê somente a
            // canônica, evitando qualquer escrita destrutiva em backends antigos.
            if let d = await reconcile(canonical: canon, legacy: key.legacy) {
                return OpenedSession(att: canon, mirror: key.legacy, data: d)
            }
            guard let d = await fetch(canon) else { return nil }
            return OpenedSession(att: adoptedAtt(d, requested: canon),
                                 mirror: nil, data: d)
        }
    }

    private static func reconcile(canonical: String, legacy: String) async -> Data? {
        let data = await post("/session/reconcile", [
            "canonicalAttachmentId": canonical,
            "legacyAttachmentId": legacy,
        ])
        invalidateCachedReads(att: canonical, mirror: legacy)
        return data
    }

    /// Mesclagem legada mantida apenas para compatibilidade de testes antigos.
    /// O fluxo de produção não a usa: comentários no nível raiz não carregam a
    /// identidade da versão e portanto não podem ser conciliados com segurança.
    /// União dos comentários por `id` — na colisão vale a versão do documento
    /// PREFERIDO (o mais novo por `updatedAt`); status e clickupCommentId vêm
    /// do preferido, com fallback no outro. Pura para ser testável.
    static func mergeSessions(preferred: [String: Any],
                              other: [String: Any]) -> [String: Any] {
        var merged = preferred
        let pc = (preferred["comments"] as? [[String: Any]]) ?? []
        let ocm = (other["comments"] as? [[String: Any]]) ?? []
        var seen = Set(pc.compactMap { $0["id"] as? String })
        var union = pc
        for c in ocm {
            guard let id = c["id"] as? String else { union.append(c); continue }
            if !seen.contains(id) { union.append(c); seen.insert(id) }
        }
        merged["comments"] = union
        if (merged["status"] as? String)?.isEmpty ?? true {
            merged["status"] = other["status"] ?? "in_review"
        }
        if merged["clickupCommentId"] == nil || merged["clickupCommentId"] is NSNull {
            if let o = other["clickupCommentId"], !(o is NSNull) {
                merged["clickupCommentId"] = o
            }
        }
        return merged
    }

    // ── /session/resolve (load-or-create numa chave EXPLÍCITA) ───────────────

    static func resolve(att: String, mediaUrl: String, ext: String, title: String,
                        taskId: String, listId: String?, uploaderId: Int?) async -> Data? {
        var body: [String: Any] = [
            "attachmentId": att,
            "taskId": taskId,
            "mediaUrl": mediaUrl,
            "mediaTitle": title,
            "mediaKind": mediaKind(forExt: ext),
        ]
        if let listId { body["listId"] = listId }
        if let uploaderId {
            body["uploaderId"] = uploaderId
            body["createdById"] = uploaderId   // the uploader owns/created it
        }
        let data = await post("/session/resolve", body)
        // resolve is load-or-create: it may have just created the session.
        invalidateCachedReads(att: att)
        return data
    }

    // ── /session/save (chave explícita + espelho opcional) ───────────────────

    /// Persist the full review (debounced by the caller). `att` é a chave ATIVA
    /// escolhida na abertura; `mirror` recebe o mesmo estado quando um blob
    /// legado coexiste (links antigos continuam atuais).
    @discardableResult
    static func save(att: String, mirror: String?, payloadData: Data) async -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return false }
        return await save(att: att, mirror: mirror,
                          versionId: obj["versionId"] as? String,
                          status: obj["status"] as? String,
                          comments: obj["comments"] as? [Any] ?? [],
                          clickupCommentId: nil)
    }

    @discardableResult
    static func save(att: String, mirror: String?, versionId: String? = nil,
                     status: String?,
                     comments: [Any], clickupCommentId: String?) async -> Bool {
        var body: [String: Any] = [
            "reviewId": att,
            "versionId": versionId ?? "v1",
            "status": status ?? "in_review",
            "comments": comments,
        ]
        if let clickupCommentId { body["clickupCommentId"] = clickupCommentId }
        let ok = await post("/session/save", body) != nil
        if let mirror, mirror != att {
            body["reviewId"] = mirror
            _ = await post("/session/save", body)
        }
        invalidateCachedReads(att: att, mirror: mirror)
        return ok
    }

    /// Final flush for the explicit "Concluir review" action. Unlike ordinary
    /// autosave this writes `concludedAt` on the Worker. Apollo only consumes
    /// VER REVIEW when the accompanying status is also `approved`.
    @discardableResult
    static func conclude(att: String, mirror: String?, payloadData: Data) async -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return false }
        var body: [String: Any] = [
            "reviewId": att,
            "versionId": obj["versionId"] as? String ?? "v1",
            "status": obj["status"] as? String ?? "in_review",
            "comments": obj["comments"] as? [Any] ?? [],
        ]
        let ok = await post("/session/conclude", body) != nil
        if let mirror, mirror != att {
            body["reviewId"] = mirror
            _ = await post("/session/conclude", body)
        }
        invalidateCachedReads(att: att, mirror: mirror)
        return ok
    }

    /// Reads the explicit Review toggle without mutating it. `CONCLUIR` in the
    /// task list is never allowed to approve a review implicitly.
    static func payloadIsApproved(_ payloadData: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payloadData)
            as? [String: Any] else { return false }
        return (object["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "approved"
    }

    static func payloadVersionId(_ payloadData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payloadData)
            as? [String: Any] else { return nil }
        return normalizedIdentifier(object["versionId"] as? String)
    }

    static func payloadStatus(_ payloadData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payloadData)
            as? [String: Any] else { return nil }
        return normalizedIdentifier(object["status"] as? String)
    }

    /// Reads the state of one exact media version from a resolved review.
    ///
    /// The root `status`, `comments` and `concludedAt` are merely a projection
    /// of `currentVersionId`. Using them to confirm a submit from another
    /// selected version caused the native reviewer to show a false success and
    /// left VER REVIEW pending. This parser deliberately refuses to fall back
    /// to the root when the requested version state is absent.
    static func versionMeta(in resolvedData: Data, versionId: String) -> Meta? {
        guard let object = try? JSONSerialization.jsonObject(with: resolvedData)
            as? [String: Any],
              let requested = normalizedIdentifier(versionId),
              let states = object["versionStates"] as? [String: Any],
              let matchingKey = states.keys.first(where: {
                  normalizedIdentifier($0) == requested
              }),
              let state = states[matchingKey] as? [String: Any]
        else { return nil }

        let comments = state["comments"] as? [Any] ?? []
        let versions = object["versions"] as? [[String: Any]] ?? []
        let version = versions.first {
            normalizedIdentifier($0["versionId"] as? String) == requested
        }
        return Meta(
            exists: true,
            updatedAt: state["updatedAt"] as? String,
            status: state["status"] as? String,
            commentCount: comments.count,
            concludedAt: state["concludedAt"] as? String,
            reviewId: object["reviewId"] as? String,
            currentVersionId: object["currentVersionId"] as? String,
            mediaTitle: (version?["mediaTitle"] as? String)
                ?? (object["mediaTitle"] as? String),
            evaluatedVersionId: matchingKey
        )
    }

    /// True only when the resolved review already contains the requested media
    /// version. Opening an older/newer existing version must be read-only: the
    /// previous implementation compared it with `currentVersionId` and called
    /// `/session/version` on every switch, which both rewrote review state and
    /// multiplied KV traffic.
    static func containsVersion(in resolvedData: Data, versionId: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: resolvedData)
                as? [String: Any],
              let requested = normalizedIdentifier(versionId)
        else { return false }

        if let versions = object["versions"] as? [[String: Any]],
           versions.contains(where: {
               normalizedIdentifier($0["versionId"] as? String) == requested
           }) {
            return true
        }
        if let states = object["versionStates"] as? [String: Any] {
            return states.keys.contains {
                normalizedIdentifier($0) == requested
            }
        }
        return false
    }

    /// Produces the exact session payload required by the inline approval
    /// toggle. Only the top-level review status changes; comments, versions
    /// and future fields remain byte-for-byte equivalent after JSON decoding.
    static func payload(_ payloadData: Data, settingApproved approved: Bool) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: payloadData)
            as? [String: Any] else { return nil }
        object["status"] = approved ? "approved" : "in_review"
        return try? JSONSerialization.data(withJSONObject: object)
    }

    @discardableResult
    static func conclude(payloadData: Data) async -> Bool {
        guard let (att, mirror) = await activeKeys(payloadData: payloadData)
        else { return false }
        return await conclude(att: att, mirror: mirror, payloadData: payloadData)
    }

    /// Advances the media inside an existing logical review while preserving
    /// its comments, checkboxes and public link. `reviewId` is the stable V1
    /// session key; `attachmentId` identifies only this newly uploaded version.
    @discardableResult
    static func registerVersion(reviewId: String, version: Int,
                                attachmentId: String, mediaURL: URL,
                                mediaTitle: String, ext: String,
                                taskId: String, uploaderId: Int?) async -> Bool {
        await registerVersion(reviewId: reviewId, versionId: "v\(version)",
                              attachmentId: attachmentId, mediaURL: mediaURL,
                              mediaTitle: mediaTitle, ext: ext,
                              taskId: taskId, uploaderId: uploaderId)
    }

    /// String form used when Apollo opens a persisted pending review. It
    /// repairs older sessions that saved a `versionStates.v4` snapshot without
    /// first inserting V4 into the selectable media catalog.
    @discardableResult
    static func registerVersion(reviewId: String, versionId: String,
                                attachmentId: String, mediaURL: URL,
                                mediaTitle: String, ext: String,
                                taskId: String, uploaderId: Int?) async -> Bool {
        var body: [String: Any] = [
            "reviewId": reviewId,
            "versionId": versionId,
            "attachmentId": attachmentId,
            "mediaUrl": mediaURL.absoluteString,
            "mediaTitle": mediaTitle,
            "mediaKind": mediaKind(forExt: ext),
            "ext": ext,
            "taskId": taskId,
        ]
        if let uploaderId { body["uploaderId"] = uploaderId }
        let ok = await post("/session/version", body) != nil
        invalidateCachedReads(att: reviewId)
        return ok
    }

    /// Compat: salvar derivando a chave do payload (usado quando não há
    /// contexto de sessão — ex.: reposte de um JSON salvo). Prefere a chave
    /// canônica EXISTENTE; nunca cria uma segunda sessão por engano.
    @discardableResult
    static func save(payloadData: Data) async -> Bool {
        guard let (att, mirror) = await activeKeys(payloadData: payloadData)
        else { return false }
        return await save(att: att, mirror: mirror, payloadData: payloadData)
    }

    // ── Single ClickUp conclusion comment (delete+repost, not accumulate) ────
    // The id of the one "Ver review" comment for this review, stored in the
    // blob so any Apollo instance replaces the same comment instead of posting
    // a new one each conclusion. `payloadData` is the ReviewPayload JSON.
    static func clickupCommentId(payloadData: Data) async -> String? {
        guard let (att, _) = await activeKeys(payloadData: payloadData),
              let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { return nil }
        // A sessão já existe (activeKeys só devolve chaves vivas ou o alvo de
        // criação); resolve aqui é seguro e devolve o clickupCommentId.
        var body: [String: Any] = [
            "attachmentId": att,
            "taskId": obj["taskId"] ?? "",
            "mediaUrl": obj["mediaUrl"] ?? "",
            "mediaTitle": obj["mediaTitle"] ?? "",
            "mediaKind": mediaKind(forExt: obj["ext"] as? String ?? ""),
        ]
        if let up = obj["uploaderId"] { body["uploaderId"] = up }
        guard let data = await post("/session/resolve", body),
              let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return r["clickupCommentId"] as? String
    }

    static func setClickupCommentId(payloadData: Data, id: String?) async {
        guard let (att, mirror) = await activeKeys(payloadData: payloadData) else { return }
        var body: [String: Any] = ["reviewId": att]
        body["clickupCommentId"] = id ?? NSNull()
        _ = await post("/session/save", body)
        if let mirror, mirror != att {
            body["reviewId"] = mirror
            _ = await post("/session/save", body)
        }
        invalidateCachedReads(att: att, mirror: mirror)
    }

    /// Chave ativa (+ espelho legado quando coexiste) a partir de um payload —
    /// leitura via meta, sem criar sessão nas duas chaves.
    private static func activeKeys(payloadData: Data) async -> (String, String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let mediaUrl = obj["mediaUrl"] as? String, !mediaUrl.isEmpty
        else { return nil }
        let key = sessionKey(attachmentId: obj["attachmentId"] as? String,
                             mediaUrl: mediaUrl)
        guard let canon = key.canonical else { return (key.legacy, nil) }
        let legacyExists = (await meta(att: key.legacy))?.exists == true
        let canonExists  = (await meta(att: canon))?.exists == true
        if canonExists { return (canon, legacyExists ? key.legacy : nil) }
        if legacyExists { return (key.legacy, nil) }
        return (canon, nil)
    }

    // ── Local activity state (drives REVIEW + notifications) ────────────────
    // Local-only state: the `updatedAt` this user explicitly completed for each
    // review. A review whose remote `updatedAt` is newer than this got changed
    // by someone else → badge. Merely opening/closing never advances it.
    static func lastSeen(att: String) -> String? {
        UserDefaults.standard.string(forKey: "reviewSeen.\(att)")
    }
    static func lastSeenCommentCount(att: String) -> Int? {
        let key = "reviewCommentSeen.\(att)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }
    static func lastObservedUpdatedAt(att: String) -> String? {
        UserDefaults.standard.string(forKey: "reviewObserved.\(att)")
    }
    static func lastObservedStatus(att: String) -> String? {
        UserDefaults.standard.string(forKey: "reviewObservedStatus.\(att)")
    }
    static func lastObservedCommentCount(att: String) -> Int? {
        let key = "reviewObservedComments.\(att)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }

    /// Records the last server state Apollo polled without consuming the
    /// review. This baseline is deliberately distinct from `reviewSeen`: a
    /// background poll must be able to notice a later status/check/annotation
    /// change while keeping the REVIEW capsule visible until the user opens it.
    static func markObserved(att: String, meta: Meta) {
        if let updatedAt = meta.updatedAt {
            UserDefaults.standard.set(updatedAt, forKey: "reviewObserved.\(att)")
        }
        if let status = meta.status {
            UserDefaults.standard.set(status, forKey: "reviewObservedStatus.\(att)")
        }
        UserDefaults.standard.set(max(0, meta.commentCount),
                                  forKey: "reviewObservedComments.\(att)")
    }

    static func markSeen(att: String, updatedAt: String?, commentCount: Int? = nil,
                         status: String? = nil) {
        if let u = updatedAt {
            UserDefaults.standard.set(u, forKey: "reviewSeen.\(att)")
        }
        if let commentCount {
            UserDefaults.standard.set(max(0, commentCount),
                                      forKey: "reviewCommentSeen.\(att)")
        }
        markObserved(att: att,
                     meta: Meta(exists: true, updatedAt: updatedAt,
                                status: status, commentCount: commentCount ?? 0))
    }
    /// True when the live review contains comments the user has not opened yet,
    /// or when a previously-opened session changed for another reason (status,
    /// annotations, resolution). A never-opened empty session is deliberately
    /// ignored: merely resolving a review link must not create a false badge.
    static func hasUnseenUpdate(meta: Meta, att: String) -> Bool {
        guard meta.exists else { return false }

        // Session/media lifecycle writes are not review activity. This guard
        // deliberately runs before every updatedAt comparison so that upload,
        // link creation, version registration and a repeated empty save cannot
        // manufacture VER REVIEW.
        guard meta.hasReviewerActivityEvidence else { return false }

        let seenComments = lastSeenCommentCount(att: att) ?? 0
        if meta.commentCount > seenComments { return true }

        // Once the user has opened this review, `updatedAt` is the complete
        // activity signal: comment edits, annotations, resolved checkboxes and
        // status transitions all persist through /session/save and bump it.
        if let remote = meta.updatedAt, let seen = lastSeen(att: att) {
            return remote > seen
        }

        // A first observation that already contains a non-default status proves
        // that a reviewer actually did something and is actionable.
        let status = meta.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let status, !status.isEmpty, status != "in_review" { return true }

        // Conclusion is reviewer activity even when approval is still off.
        // It keeps VER REVIEW pending; only approved + concluded consumes it.
        if !(meta.concludedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true) { return true }

        // For an active review, compare against the prior poll. This catches
        // edits/checks that keep the same comment count. Pristine sessions were
        // already rejected above, so technical media writes cannot reach here.
        if let remote = meta.updatedAt,
           let observed = lastObservedUpdatedAt(att: att),
           remote > observed {
            return true
        }
        if let priorStatus = lastObservedStatus(att: att),
           priorStatus != meta.status {
            return true
        }
        if let priorCount = lastObservedCommentCount(att: att),
           priorCount != meta.commentCount {
            return true
        }
        return false
    }

    /// Computes activity before advancing the observation baseline. Callers
    /// that poll should use this method, not `markObserved` +
    /// `hasUnseenUpdate` in the opposite order.
    @discardableResult
    static func observe(meta: Meta, att: String) -> Bool {
        let unseen = hasUnseenUpdate(meta: meta, att: att)
        markObserved(att: att, meta: meta)
        return unseen
    }

    // ── Read dedup + quota backoff ───────────────────────────────────────────

    /// Serializes the client's KV-read discipline: a short-TTL cache keyed by
    /// `reviewId#versionId` (deduplicates the row probe, the watcher loop and
    /// the flow sheet) plus an exponential cooldown while the backend errors.
    /// The daily `KV get() limit exceeded` outage was caused precisely by many
    /// pollers issuing the same read; this is the single choke point.
    private static let readGate = ReadGate()

    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedMetas: [String: (expires: Date, meta: Meta)] = [:]
        private var consecutiveFailures = 0
        private var cooldownUntil: Date?
        /// MUST stay below the fastest poll interval (45s) — a TTL longer
        /// than the poll would make every poll a cache hit and silently
        /// freeze discovery at the cache age instead of the poll cadence.
        private let ttl: TimeInterval = 30

        func cachedMeta(for key: String) -> Meta? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = cachedMetas[key], entry.expires > Date() else {
                cachedMetas.removeValue(forKey: key)
                return nil
            }
            return entry.meta
        }

        func cache(_ meta: Meta, for key: String) {
            lock.lock(); defer { lock.unlock() }
            cachedMetas[key] = (Date().addingTimeInterval(ttl), meta)
        }

        /// Every write path calls this so the next read observes its effect
        /// immediately. `att` prefixes both the root key and every
        /// `att#versionId` variant.
        func invalidate(att: String) {
            lock.lock(); defer { lock.unlock() }
            cachedMetas = cachedMetas.filter { key, _ in
                key != att && !key.hasPrefix("\(att)#")
            }
        }

        var isCoolingDown: Bool {
            lock.lock(); defer { lock.unlock() }
            guard let cooldownUntil else { return false }
            return cooldownUntil > Date()
        }

        func recordReadFailure() {
            lock.lock(); defer { lock.unlock() }
            consecutiveFailures += 1
            let delay = min(900, 30 * pow(2, Double(consecutiveFailures - 1)))
            cooldownUntil = Date().addingTimeInterval(delay)
        }

        func recordReadSuccess() {
            lock.lock(); defer { lock.unlock() }
            consecutiveFailures = 0
            cooldownUntil = nil
        }
    }

    /// Drops cached reads for one review after any write to it.
    private static func invalidateCachedReads(att: String, mirror: String? = nil) {
        readGate.invalidate(att: att)
        if let mirror { readGate.invalidate(att: mirror) }
    }

    // ── helpers ──────────────────────────────────────────────────────────────
    static func mediaKind(forExt ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "mov", "m4v", "webm", "avi", "mkv": return "video"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff": return "image"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "audio"
        default: return "document"
        }
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !normalized.isEmpty else { return nil }
        return normalized
    }

    @discardableResult
    private static func post(_ path: String, _ body: [String: Any]) async -> Data? {
        guard let url = URL(string: base + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            Log.error("Review backend \(path): falha de transporte")
            return nil
        }
        guard http.statusCode < 300 else {
            let detail = String(data: respData, encoding: .utf8) ?? "sem resposta"
            Log.error("Review backend \(path): HTTP \(http.statusCode) \(detail)")
            return nil
        }
        return respData
    }
}
