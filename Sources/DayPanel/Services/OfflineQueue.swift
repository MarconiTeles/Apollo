import Foundation
import Combine

/// Durable queue of mutations that couldn't reach the server.
/// Survives app relaunches via `UserDefaults` so a status change
/// made on the subway makes it to ClickUp the moment the user
/// gets back into wi-fi (even after closing the app).
///
/// Wire-up:
/// - `AppState.patchTask` (and friends) call `enqueue(_:)` instead
///   of bailing when offline / on `.offline` / `.serverError`.
/// - When `NetworkMonitor.isOnline` flips to `true`, AppState calls
///   `OfflineQueue.shared.drain(executor:)`. The executor receives
///   each operation in FIFO order and runs the appropriate
///   ClickUpService method. On success the op is removed; on
///   transient failure it stays in the queue with `attempts++`.
///
/// Persistence shape: a JSON array of `PendingMutation` blobs under
/// UserDefaults key `dp_offline_queue_v1`. The op enum's raw
/// values are intentionally stable strings, not Swift type names,
/// so the format survives refactors.
@MainActor
final class OfflineQueue: ObservableObject {

    static let shared = OfflineQueue()

    /// Snapshot of the queue, in FIFO order. SwiftUI observes
    /// `count` to show the toolbar pill ("↻ 3 pendentes").
    @Published private(set) var pending: [PendingMutation] = []

    /// UserDefaults key the queue persists under. Versioned in the
    /// suffix so a future format change can leave old payloads
    /// untouched.
    private let storageKey = "dp_offline_queue_v1"

    /// Per-launch monotonic id source for new entries — used as
    /// the `Identifiable.id` for SwiftUI ForEach in any
    /// debug/inspector view.
    private var idCounter: Int = 0

    private init() {
        load()
    }

    // MARK: - Public API

    /// Push a new operation onto the tail of the queue, persist,
    /// and notify observers.
    func enqueue(_ op: PendingMutation.Op,
                 originatingFromOfflineState: Bool = false) {
        idCounter += 1
        let mut = PendingMutation(
            id: idCounter,
            op: op,
            createdAt: Date(),
            attempts: 0
        )
        pending.append(mut)
        save()
    }

    /// Drain the queue head-first. The executor closure runs each
    /// op against the real services; if it throws an `APIError`
    /// that's `.isTransient`, the op stays at the head and we stop
    /// draining (preserving order). On a permanent failure the op
    /// is dropped and an `onPermanentFailure` callback fires so
    /// the user can be told something more specific than "still
    /// pending".
    ///
    /// Idempotent — calling twice while a drain is in progress
    /// is a no-op via the `isDraining` flag.
    func drain(executor: @escaping (PendingMutation.Op) async throws -> Void,
               onPermanentFailure: @escaping (PendingMutation, Error) -> Void
                    = { _, _ in }) {
        guard !isDraining else { return }
        isDraining = true
        Task { @MainActor in
            defer { isDraining = false }
            while let head = pending.first {
                do {
                    try await executor(head.op)
                    // Successful → remove and continue.
                    if !pending.isEmpty { pending.removeFirst() }
                    save()
                } catch let api as APIError where api.isTransient {
                    // Bump attempts on the head op and stop the
                    // drain — we'll retry on the next reconnect.
                    var mutated = head
                    mutated.attempts += 1
                    if !pending.isEmpty { pending[0] = mutated }
                    save()
                    return
                } catch {
                    // Permanent failure — drop the op and let the
                    // caller decide how to report it.
                    let removed = head
                    if !pending.isEmpty { pending.removeFirst() }
                    save()
                    onPermanentFailure(removed, error)
                }
            }
        }
    }

    /// Drop everything. Used by "Esquecer dispositivo" / logout
    /// flows — we don't want pending mutations from a previous
    /// account to fire against a new one.
    func clearAll() {
        pending.removeAll()
        save()
    }

    // MARK: - Private

    private var isDraining = false

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(
                [PendingMutation].self, from: data)
        else { return }
        pending = decoded
        idCounter = decoded.map(\.id).max() ?? 0
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(pending)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            NSLog("[Apollo] OfflineQueue save failed: %@",
                  error.localizedDescription)
        }
    }
}

// MARK: - PendingMutation

/// One enqueued mutation. `op` is the typed operation discriminant
/// + its payload; the rest is bookkeeping. Codable for persistence.
struct PendingMutation: Codable, Identifiable, Equatable {
    let id: Int
    let op: Op
    let createdAt: Date
    var attempts: Int

    /// Discriminated union of the operations Apollo currently
    /// supports queueing. Adding a new case here is the canonical
    /// way to extend the offline contract; the queue is otherwise
    /// content-agnostic.
    enum Op: Codable, Equatable {
        case updateTaskStatus(taskId: String, status: String)
        case completeTask(taskId: String)
        case patchTaskFields(taskId: String, fields: [String: PlainValue])
    }
}

// MARK: - PlainValue
//
// `[String: Any]` isn't Codable. `PlainValue` is the small subset
// of JSON scalars we actually send to ClickUp's PUT endpoints —
// enough to carry "name=…", "priority=2", "due_date=12345…",
// "archived=true", "due_date=null". Anything more exotic should
// add a dedicated case to `PendingMutation.Op` instead.
enum PlainValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    /// Decode the wire form into the JSON-ready value
    /// `JSONSerialization.data` wants. Use this when replaying
    /// queued patches against `ClickUpService.updateTask`.
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i):    return i
        case .double(let d): return d
        case .bool(let b):   return b
        case .null:          return NSNull()
        }
    }

    /// Convenience for the encoding side — convert what AppState
    /// would have sent in `[String: Any]` form. Falls back to a
    /// JSON string for anything we don't recognise so a future
    /// odd field doesn't crash the queue (it just won't replay
    /// usefully).
    static func from(_ value: Any) -> PlainValue {
        switch value {
        case let s as String: return .string(s)
        case let i as Int:    return .int(i)
        case let d as Double: return .double(d)
        case let b as Bool:   return .bool(b)
        case is NSNull:       return .null
        default:
            return .string(String(describing: value))
        }
    }
}
