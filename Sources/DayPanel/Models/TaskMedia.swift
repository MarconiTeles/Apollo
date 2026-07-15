import CryptoKit
import Foundation

enum TaskMediaRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case hook
    case body
    case video

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    static func inferred(from fileName: String) -> TaskMediaRole? {
        let raw = fileName.decomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let tokens = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.contains("hook") || tokens.contains(where: { $0.range(of: #"^h\d+$"#, options: .regularExpression) != nil }) {
            return .hook
        }
        if tokens.contains("body") || tokens.contains("corpo")
            || tokens.contains(where: { $0.range(of: #"^b\d+$"#, options: .regularExpression) != nil }) {
            return .body
        }
        if tokens.contains("video") || tokens.contains("final") || tokens.contains("completo") {
            return .video
        }
        return nil
    }
}

struct TaskMediaRevision: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let number: Int
    let contentHash: String
    let originalFileName: String
    var attachmentId: String?
    var remoteURL: URL?
    var localURL: URL?

    init(id: UUID = UUID(), number: Int, contentHash: String,
         originalFileName: String, attachmentId: String? = nil,
         remoteURL: URL? = nil, localURL: URL? = nil) {
        self.id = id
        self.number = number
        self.contentHash = contentHash
        self.originalFileName = originalFileName
        self.attachmentId = attachmentId
        self.remoteURL = remoteURL
        self.localURL = localURL
    }
}

struct TaskMediaAsset: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let role: TaskMediaRole
    var displayName: String
    var revisions: [TaskMediaRevision]
    var activeRevisionId: UUID

    var activeRevision: TaskMediaRevision? {
        revisions.first { $0.id == activeRevisionId }
    }

    init(id: UUID = UUID(), role: TaskMediaRole, displayName: String,
         revisions: [TaskMediaRevision], activeRevisionId: UUID) {
        self.id = id
        self.role = role
        self.displayName = displayName
        self.revisions = revisions
        self.activeRevisionId = activeRevisionId
    }
}

struct TaskMediaOutputLineage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let hookAssetId: UUID?
    let bodyAssetId: UUID?
    let videoAssetId: UUID?

    static func combination(hook: UUID, body: UUID) -> Self {
        .init(id: "hook:\(hook.uuidString)|body:\(body.uuidString)",
              hookAssetId: hook, bodyAssetId: body, videoAssetId: nil)
    }

    static func direct(video: UUID) -> Self {
        .init(id: "video:\(video.uuidString)",
              hookAssetId: nil, bodyAssetId: nil, videoAssetId: video)
    }

    var isComposition: Bool {
        hookAssetId != nil && bodyAssetId != nil && videoAssetId == nil
    }
}

struct TaskMediaOutputVersion: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let lineageId: String
    let version: Int
    let fileName: String
    let sourceRevisionIds: [UUID]
    var attachmentId: String?
    var remoteURL: URL?

    init(id: UUID = UUID(), lineageId: String, version: Int,
         fileName: String, sourceRevisionIds: [UUID],
         attachmentId: String? = nil, remoteURL: URL? = nil) {
        self.id = id
        self.lineageId = lineageId
        self.version = version
        self.fileName = fileName
        self.sourceRevisionIds = sourceRevisionIds
        self.attachmentId = attachmentId
        self.remoteURL = remoteURL
    }
}

struct TaskMediaCatalog: Codable, Equatable, Sendable {
    var taskId: String
    var sequence: Int
    var assets: [TaskMediaAsset]
    var lineages: [TaskMediaOutputLineage]
    var outputs: [TaskMediaOutputVersion]

    static func empty(taskId: String) -> Self {
        .init(taskId: taskId, sequence: 0, assets: [], lineages: [], outputs: [])
    }

    func asset(id: UUID) -> TaskMediaAsset? { assets.first { $0.id == id } }
    func latestVersion(for lineageId: String) -> Int {
        outputs.lazy.filter { $0.lineageId == lineageId }.map(\.version).max() ?? 0
    }

    func latestOutput(for lineageId: String) -> TaskMediaOutputVersion? {
        outputs.filter { $0.lineageId == lineageId }
            .max { lhs, rhs in lhs.version < rhs.version }
    }

    /// Returns the independently replaceable parts of one composed output in
    /// the order users expect to see them: HOOK, then BODY. A direct VIDEO has
    /// no separable components because Apollo does not invent source media that
    /// was not preserved in the catalog.
    func replacementComponents(for lineage: TaskMediaOutputLineage) -> [TaskMediaAsset] {
        guard lineage.isComposition else { return [] }
        return [lineage.hookAssetId, lineage.bodyAssetId]
            .compactMap { $0 }
            .compactMap { asset(id: $0) }
    }

    /// Backfills videos that were attached before Apollo introduced its media
    /// manifest. They remain direct VIDEO assets, so Substituir arquivo can
    /// immediately create V2 without asking the user to upload V1 again.
    @discardableResult
    mutating func importLegacyVideoAttachments(_ attachments: [CUTask.Attachment]) -> Int {
        let videoExtensions = Set(["mov", "mp4", "m4v", "avi", "mkv", "webm"])
        var knownIds = Set(assets.flatMap(\.revisions).compactMap(\.attachmentId))
            .union(outputs.compactMap(\.attachmentId))
        var knownURLs = Set(assets.flatMap(\.revisions).compactMap { $0.remoteURL?.absoluteString })
            .union(outputs.compactMap { $0.remoteURL?.absoluteString })
        var imported = 0

        for attachment in attachments {
            guard videoExtensions.contains(attachment.ext.lowercased()),
                  !attachment.title.hasPrefix(TaskMediaTechnicalName.sourcePrefix),
                  !attachment.title.hasPrefix(TaskMediaTechnicalName.manifestPrefix),
                  !knownIds.contains(attachment.id),
                  !knownURLs.contains(attachment.url),
                  let remoteURL = URL(string: attachment.url) else { continue }

            let identity = "legacy:\(attachment.id):\(attachment.url)"
            let digest = SHA256.hash(data: Data(identity.utf8))
            let hash = digest.map { String(format: "%02x", $0) }.joined()
            let assetId = Self.stableUUID(from: digest)
            let revisionId = Self.stableUUID(from: SHA256.hash(data: Data("revision:\(identity)".utf8)))
            let version = Self.versionNumber(in: attachment.title)
            let revision = TaskMediaRevision(
                id: revisionId,
                number: 1,
                contentHash: hash,
                originalFileName: attachment.title,
                attachmentId: attachment.id,
                remoteURL: remoteURL
            )
            let asset = TaskMediaAsset(
                id: assetId,
                role: .video,
                displayName: (attachment.title as NSString).deletingPathExtension,
                revisions: [revision],
                activeRevisionId: revisionId
            )
            let lineage = TaskMediaOutputLineage.direct(video: assetId)
            assets.append(asset)
            lineages.append(lineage)
            outputs.append(TaskMediaOutputVersion(
                lineageId: lineage.id,
                version: version,
                fileName: attachment.title,
                sourceRevisionIds: [revisionId],
                attachmentId: attachment.id,
                remoteURL: remoteURL
            ))
            knownIds.insert(attachment.id)
            knownURLs.insert(attachment.url)
            imported += 1
        }
        if imported > 0 { sequence += 1 }
        return imported
    }

    private static func versionNumber(in fileName: String) -> Int {
        let pattern = #"(?i)(?:^|[ ._-])v(\d+)(?:[ ._-]|\.[a-z0-9]+$|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: fileName,
                                           range: NSRange(fileName.startIndex..., in: fileName)),
              let range = Range(match.range(at: 1), in: fileName),
              let value = Int(fileName[range]) else { return 1 }
        return max(1, value)
    }

    private static func stableUUID<D: Sequence>(from digest: D) -> UUID where D.Element == UInt8 {
        var bytes = Array(digest.prefix(16))
        while bytes.count < 16 { bytes.append(0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct TaskMediaSelection: Identifiable, Hashable, Sendable {
    let id: UUID
    let fileURL: URL
    var role: TaskMediaRole?
    var contentHash: String?

    init(id: UUID = UUID(), fileURL: URL, role: TaskMediaRole? = nil,
         contentHash: String? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.role = role ?? TaskMediaRole.inferred(from: fileURL.lastPathComponent)
        self.contentHash = contentHash
    }
}

struct TaskMediaPlannedOutput: Identifiable, Hashable, Sendable {
    let id: UUID
    let lineage: TaskMediaOutputLineage
    let version: Int
    let hookAssetId: UUID?
    let bodyAssetId: UUID?
    let videoAssetId: UUID?
    var displayFileName: String

    init(id: UUID = UUID(), lineage: TaskMediaOutputLineage, version: Int,
         displayFileName: String) {
        self.id = id
        self.lineage = lineage
        self.version = version
        self.hookAssetId = lineage.hookAssetId
        self.bodyAssetId = lineage.bodyAssetId
        self.videoAssetId = lineage.videoAssetId
        self.displayFileName = displayFileName
    }
}

struct TaskMediaPlan: Sendable {
    var catalog: TaskMediaCatalog
    var newAssetIds: Set<UUID>
    var pendingRevisionAssetIds: Set<UUID>
    var outputs: [TaskMediaPlannedOutput]
}

enum TaskMediaPlannerError: LocalizedError, Equatable {
    case unclassifiedFiles
    case duplicateFiles([String])
    case missingCounterpart(TaskMediaRole)
    case assetNotFound

    var errorDescription: String? {
        switch self {
        case .unclassifiedFiles: return "Classifique todos os arquivos antes de continuar."
        case .duplicateFiles(let names): return "Arquivos já presentes: \(names.joined(separator: ", "))."
        case .missingCounterpart(.hook): return "Adicione ao menos um HOOK para combinar com os BODYs."
        case .missingCounterpart(.body): return "Adicione ao menos um BODY para combinar com os HOOKs."
        case .missingCounterpart: return "Falta uma fonte para criar as combinações."
        case .assetNotFound: return "A fonte selecionada não está mais disponível."
        }
    }
}

enum TaskMediaPlanner {
    static func adding(selections: [TaskMediaSelection], to existing: TaskMediaCatalog) throws -> TaskMediaPlan {
        guard selections.allSatisfy({ $0.role != nil && $0.contentHash != nil }) else {
            throw TaskMediaPlannerError.unclassifiedFiles
        }
        let knownHashes = Set(existing.assets.flatMap { $0.revisions.map(\.contentHash) })
        var seenHashes = knownHashes
        let duplicates = selections.compactMap { selection -> String? in
            guard let hash = selection.contentHash else { return selection.fileURL.lastPathComponent }
            guard seenHashes.insert(hash).inserted else { return selection.fileURL.lastPathComponent }
            return nil
        }
        guard duplicates.isEmpty else { throw TaskMediaPlannerError.duplicateFiles(duplicates) }

        var catalog = existing
        var newIds = Set<UUID>()
        for selection in selections {
            let revision = TaskMediaRevision(number: 1,
                                             contentHash: selection.contentHash!,
                                             originalFileName: selection.fileURL.lastPathComponent,
                                             localURL: selection.fileURL)
            let asset = TaskMediaAsset(role: selection.role!,
                                       displayName: selection.fileURL.deletingPathExtension().lastPathComponent,
                                       revisions: [revision], activeRevisionId: revision.id)
            catalog.assets.append(asset)
            newIds.insert(asset.id)
        }

        let hooks = catalog.assets.filter { $0.role == .hook }
        let bodies = catalog.assets.filter { $0.role == .body }
        if !newIds.isDisjoint(with: Set(hooks.map(\.id))) && bodies.isEmpty {
            throw TaskMediaPlannerError.missingCounterpart(.body)
        }
        if !newIds.isDisjoint(with: Set(bodies.map(\.id))) && hooks.isEmpty {
            throw TaskMediaPlannerError.missingCounterpart(.hook)
        }

        var outputs: [TaskMediaPlannedOutput] = []
        for hook in hooks {
            for body in bodies where newIds.contains(hook.id) || newIds.contains(body.id) {
                let lineage = TaskMediaOutputLineage.combination(hook: hook.id, body: body.id)
                if !catalog.lineages.contains(where: { $0.id == lineage.id }) { catalog.lineages.append(lineage) }
                guard catalog.latestVersion(for: lineage.id) == 0 else { continue }
                outputs.append(.init(lineage: lineage, version: 1,
                                     displayFileName: outputName(hook: hook, body: body, version: 1)))
            }
        }
        for video in catalog.assets where video.role == .video && newIds.contains(video.id) {
            let lineage = TaskMediaOutputLineage.direct(video: video.id)
            catalog.lineages.append(lineage)
            outputs.append(.init(lineage: lineage, version: 1,
                                 displayFileName: directOutputName(video: video, version: 1)))
        }
        return .init(catalog: catalog, newAssetIds: newIds,
                     pendingRevisionAssetIds: [], outputs: outputs)
    }

    static func replacing(assetId: UUID, with selection: TaskMediaSelection,
                          in existing: TaskMediaCatalog) throws -> TaskMediaPlan {
        try replacing(replacements: [assetId: selection], in: existing)
    }

    /// Plans a transactional replacement batch. Every affected logical lineage is
    /// emitted once, even when both its HOOK and BODY are replaced together.
    static func replacing(replacements: [UUID: TaskMediaSelection],
                          in existing: TaskMediaCatalog) throws -> TaskMediaPlan {
        guard !replacements.isEmpty,
              replacements.values.allSatisfy({ $0.role != nil && $0.contentHash != nil }) else {
            throw TaskMediaPlannerError.unclassifiedFiles
        }
        guard replacements.keys.allSatisfy({ existing.asset(id: $0) != nil }) else {
            throw TaskMediaPlannerError.assetNotFound
        }

        let existingHashes = Set(existing.assets.flatMap { $0.revisions.map(\.contentHash) })
        var seenHashes = existingHashes
        let duplicates = replacements.values.compactMap { selection -> String? in
            guard let hash = selection.contentHash,
                  seenHashes.insert(hash).inserted else {
                return selection.fileURL.lastPathComponent
            }
            return nil
        }
        guard duplicates.isEmpty else { throw TaskMediaPlannerError.duplicateFiles(duplicates) }

        var catalog = existing
        for (assetId, selection) in replacements {
            guard let index = catalog.assets.firstIndex(where: { $0.id == assetId }) else {
                throw TaskMediaPlannerError.assetNotFound
            }
            let asset = catalog.assets[index]
            guard selection.role == asset.role else {
                throw TaskMediaPlannerError.unclassifiedFiles
            }
            let nextRevision = (asset.revisions.map(\.number).max() ?? 0) + 1
            let revision = TaskMediaRevision(number: nextRevision,
                                             contentHash: selection.contentHash!,
                                             originalFileName: selection.fileURL.lastPathComponent,
                                             localURL: selection.fileURL)
            catalog.assets[index].revisions.append(revision)
            catalog.assets[index].activeRevisionId = revision.id
            catalog.assets[index].displayName = selection.fileURL.deletingPathExtension().lastPathComponent
        }

        var affected = [String: TaskMediaOutputLineage]()
        let activeHooks = catalog.assets.filter { $0.role == .hook }
        let activeBodies = catalog.assets.filter { $0.role == .body }
        for assetId in replacements.keys {
            guard let asset = catalog.asset(id: assetId) else { continue }
            switch asset.role {
            case .hook:
                for body in activeBodies {
                    let lineage = TaskMediaOutputLineage.combination(hook: assetId, body: body.id)
                    affected[lineage.id] = lineage
                }
            case .body:
                for hook in activeHooks {
                    let lineage = TaskMediaOutputLineage.combination(hook: hook.id, body: assetId)
                    affected[lineage.id] = lineage
                }
            case .video:
                let lineage = TaskMediaOutputLineage.direct(video: assetId)
                affected[lineage.id] = lineage
            }
        }

        var outputs: [TaskMediaPlannedOutput] = []
        for lineage in affected.values.sorted(by: { $0.id < $1.id }) {
            if !catalog.lineages.contains(where: { $0.id == lineage.id }) {
                catalog.lineages.append(lineage)
            }
            let version = catalog.latestVersion(for: lineage.id) + 1
            if let videoId = lineage.videoAssetId,
               let video = catalog.asset(id: videoId) {
                outputs.append(.init(lineage: lineage, version: version,
                                     displayFileName: directOutputName(video: video, version: version)))
            } else if let hookId = lineage.hookAssetId,
                      let bodyId = lineage.bodyAssetId,
                      let hook = catalog.asset(id: hookId),
                      let body = catalog.asset(id: bodyId) {
                outputs.append(.init(lineage: lineage, version: version,
                                     displayFileName: outputName(hook: hook, body: body, version: version)))
            }
        }
        return .init(catalog: catalog, newAssetIds: [],
                     pendingRevisionAssetIds: Set(replacements.keys), outputs: outputs)
    }

    private static func outputName(hook: TaskMediaAsset, body: TaskMediaAsset, version: Int) -> String {
        "\(safe(hook.displayName)) + \(safe(body.displayName)) · V\(version).mov"
    }

    private static func directOutputName(video: TaskMediaAsset, version: Int) -> String {
        "\(safe(video.displayName)) · V\(version).\(video.activeRevision?.originalFileName.split(separator: ".").last.map(String.init) ?? "mov")"
    }

    private static func safe(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Video" : cleaned).prefix(70))
    }
}

enum TaskMediaTechnicalName {
    static let sourcePrefix = "APOLLO_MEDIA_SOURCE__"
    static let manifestPrefix = "APOLLO_MEDIA_CATALOG__"

    static func source(asset: TaskMediaAsset, revision: TaskMediaRevision) -> String {
        let ext = (revision.originalFileName as NSString).pathExtension
        return "\(sourcePrefix)\(asset.role.rawValue.uppercased())__\(asset.id.uuidString)__R\(revision.number)__\(revision.contentHash.prefix(16))__\(revision.id.uuidString).\(ext.isEmpty ? "mov" : ext)"
    }

    static func manifest(sequence: Int) -> String {
        "\(manifestPrefix)\(String(format: "%08d", sequence)).json"
    }
}

/// One canonical naming rule shared by the editor and the transfer pipeline.
/// Keeping this outside the view prevents a name that looks valid in the UI
/// from being rejected only after the user presses Enviar.
enum TaskMediaOutputName {
    private static let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")

    static func normalized(_ raw: String, pathExtension: String = "mov") -> String? {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return nil }

        let requestedExtension = (stem as NSString).pathExtension
        if !requestedExtension.isEmpty,
           requestedExtension.caseInsensitiveCompare(pathExtension) == .orderedSame {
            stem = (stem as NSString).deletingPathExtension
        }
        stem = stem.components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return nil }

        let ext = pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(String(stem.prefix(120))).\(ext.isEmpty ? "mov" : ext.lowercased())"
    }

    static func comparisonKey(_ raw: String, pathExtension: String = "mov") -> String? {
        normalized(raw, pathExtension: pathExtension)?
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }
}

/// Persistent record of attachment ids that a newer media-flow version has
/// superseded. ClickUp's API can't delete or replace-in-place an attachment,
/// so every "Substituir" leaves the old file on the task. Apollo hides the
/// superseded ids from the attachments list so each composed video shows once,
/// at its latest version, with the new name. Read synchronously at render time.
enum AttachmentSupersession {
    private static let key = "apollo.attachments.superseded"   // [taskId: [id]]

    /// Extension-insensitive canonical form (`<uuid>.mov` → `<uuid>`).
    static func normalize(_ id: String) -> String {
        (id as NSString).deletingPathExtension
    }

    private static func all() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    static func supersededIds(taskId: String) -> Set<String> {
        Set(all()[taskId] ?? [])
    }

    static func isSuperseded(_ attachmentId: String, in set: Set<String>) -> Bool {
        !set.isEmpty && set.contains(normalize(attachmentId))
    }

    /// Records the ids as superseded. Returns true when the stored set actually
    /// grew (so callers can re-hydrate only when something changed).
    @discardableResult
    static func markSuperseded(_ ids: [String], taskId: String) -> Bool {
        let incoming = ids.map(normalize).filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return false }
        var store = all()
        var set = Set(store[taskId] ?? [])
        let before = set.count
        set.formUnion(incoming)
        guard set.count != before else { return false }
        store[taskId] = Array(set)
        UserDefaults.standard.set(store, forKey: key)
        return true
    }

    /// Marks every OUTPUT that isn't the latest of its lineage as superseded —
    /// so existing multi-version tasks collapse correctly the moment their
    /// catalog loads, without waiting for the next substitution. Returns true
    /// when the stored set grew.
    @discardableResult
    static func syncFromCatalog(_ catalog: TaskMediaCatalog, taskId: String) -> Bool {
        let byLineage = Dictionary(grouping: catalog.outputs, by: \.lineageId)
        var superseded: [String] = []
        for (_, versions) in byLineage {
            guard let latest = versions.max(by: { $0.version < $1.version }) else { continue }
            for v in versions where v.version < latest.version {
                if let aid = v.attachmentId { superseded.append(aid) }
            }
        }
        return markSuperseded(superseded, taskId: taskId)
    }
}
