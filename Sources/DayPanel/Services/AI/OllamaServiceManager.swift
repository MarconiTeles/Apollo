import Foundation
import AppKit

/// Hands-off lifecycle manager for the local Ollama daemon. Apollo
/// uses this to make the AI agent "just work" without the user
/// touching the terminal — when the app starts up with the Ollama
/// backend selected, the manager:
///
///   1. Detects whether the `ollama` binary exists on disk.
///   2. Pings `localhost:11434` to see if the daemon is up.
///   3. If not up, spawns `ollama serve` as a detached child
///      process so the daemon survives even if Apollo crashes
///      (`setsid` so it gets its own session and isn't reaped).
///   4. Picks the best installed model and writes it to
///      UserDefaults so `OllamaProvider` can use it.
///   5. If no models are installed, kicks off a `pull` of a
///      sensible default with progress callbacks for the UI.
///
/// All public methods are `async` and never block the caller more
/// than the underlying network/IO needs.
final class OllamaServiceManager: ObservableObject {

    // MARK: - Published state

    enum DaemonStatus: Equatable {
        case unknown
        case notInstalled        // `ollama` binary not found on disk
        case stopped             // installed but daemon down
        case starting            // spawning daemon, waiting for HTTP 200
        case running             // /api/tags responded
    }

    enum ModelStatus: Equatable {
        case unknown
        case ready(String)       // configured to use this model
        case noneInstalled       // daemon up but `ollama list` empty
        case pulling(String, Double, String)  // model, fraction 0…1, human stage
    }

    @Published private(set) var daemonStatus: DaemonStatus = .unknown
    @Published private(set) var modelStatus:  ModelStatus  = .unknown
    @Published private(set) var statusMessage: String = ""

    // MARK: - Internals

    /// Recommended default model. Chosen for **speed first**:
    /// ~2 GB footprint, 80+ tokens/s on M-series, NOT a reasoning
    /// model (so it answers immediately instead of generating
    /// thousands of "thinking" tokens before the response). Solid
    /// PT-BR for our use case (read-only Q&A about tasks/events).
    private static let defaultPullModel = "llama3.2:3b"

    /// Models we deliberately AVOID picking — they're either
    /// reasoning models (slow because they generate huge chain-of-
    /// thought before answering) or simply too large for fast
    /// interactive chat on average hardware.
    private static let avoidedModelTokens = [
        "qwen3", "deepseek-r1", "o1-style", "70b", "405b",
    ]

    /// Common locations Homebrew / official installer drop the
    /// `ollama` binary on macOS. Searched AFTER the bundled copy.
    private static let candidateBinaries: [String] = [
        "/opt/homebrew/bin/ollama",   // Apple Silicon Homebrew
        "/usr/local/bin/ollama",      // Intel Homebrew + manual installs
        "/Applications/Ollama.app/Contents/Resources/ollama",  // .dmg installer
    ]

    private let host = URL(string: "http://localhost:11434")!
    private var spawnedDaemon: Process?

    // MARK: - Public API

    /// One-call boot. Apollo invokes this on launch (when Ollama
    /// is the active backend) and any time Settings shows the
    /// Apollo IA pane. Idempotent — safe to call repeatedly.
    func bootstrap() async {
        statusMessage = "Verificando Ollama…"

        // Step 1: binary present?
        guard let binary = locateBinary() else {
            daemonStatus  = .notInstalled
            statusMessage = "Ollama não está instalado."
            return
        }

        // Step 2: daemon already running?
        if await isReachable() {
            daemonStatus  = .running
            await ensureModelSelected()
            return
        }

        // Step 3: spawn daemon and wait for it to come up.
        daemonStatus  = .starting
        statusMessage = "Iniciando o serviço Ollama…"
        let started = await spawnDaemon(binary: binary)
        if started {
            daemonStatus  = .running
            statusMessage = "Ollama rodando."
            await ensureModelSelected()
        } else {
            daemonStatus  = .stopped
            statusMessage = "Não consegui iniciar o serviço Ollama."
        }
    }

    /// If no model is configured (or the configured one isn't
    /// installed, or the configured one is on the avoid-list),
    /// pick a fast non-reasoning model. Pulls the default if the
    /// user has nothing usable installed.
    func ensureModelSelected() async {
        let installed = await listInstalledModels()
        let stored = UserDefaults.standard.string(forKey: "dp_ollama_model") ?? ""

        // Already configured AND not on the avoid-list → keep.
        if !stored.isEmpty,
           installed.contains(stored),
           !Self.isAvoided(stored) {
            modelStatus   = .ready(stored)
            statusMessage = "Modelo: \(stored)"
            return
        }

        // Try to pick a fast model from what's installed.
        if let best = pickBest(from: installed) {
            UserDefaults.standard.set(best, forKey: "dp_ollama_model")
            modelStatus   = .ready(best)
            statusMessage = "Modelo: \(best)"
            return
        }

        // Nothing usable installed (only avoided models, or no
        // models at all) — pull the fast default.
        modelStatus   = .pulling(Self.defaultPullModel, 0, "Baixando modelo rápido…")
        statusMessage = "Baixando \(Self.defaultPullModel) (~2 GB, leva ~1 min)…"
        let ok = await pullModel(Self.defaultPullModel)
        if ok {
            UserDefaults.standard.set(Self.defaultPullModel, forKey: "dp_ollama_model")
            modelStatus   = .ready(Self.defaultPullModel)
            statusMessage = "Modelo \(Self.defaultPullModel) pronto."
        } else {
            modelStatus   = .noneInstalled
            statusMessage = "Falha no download do modelo."
        }
    }

    private static func isAvoided(_ name: String) -> Bool {
        let lower = name.lowercased()
        return avoidedModelTokens.contains { lower.contains($0) }
    }

    /// Open the official Ollama download page so the user can
    /// install via the .dmg. Used by the "Install Ollama"
    /// action surfaced when `daemonStatus == .notInstalled`.
    func openInstallPage() {
        if let url = URL(string: "https://ollama.com/download/mac") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Detection

    private func locateBinary() -> URL? {
        let fm = FileManager.default

        // 1. Bundled inside `Apollo.app/Contents/Resources/ollama`.
        // This is the path Apollo ships with — zero user setup
        // required. The build script (`build.sh`) copies the
        // universal Ollama binary into this location at every
        // build.
        if let bundled = Bundle.main.url(forResource: "ollama",
                                         withExtension: nil),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        // 2. Fallback to system-wide installations — handy for
        // developer machines that don't have the bundled copy
        // (e.g. running directly from `swift run`) or as a
        // graceful degradation if the bundled binary is missing.
        for path in Self.candidateBinaries
            where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private func isReachable() async -> Bool {
        var req = URLRequest(url: host.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Daemon control

    /// Spawns `ollama serve` as a detached child. Polls
    /// `/api/tags` for up to ~10s to confirm the server is up.
    private func spawnDaemon(binary: URL) async -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]

        // Drop daemon stdout/stderr into a logfile so they don't
        // get mixed into Apollo's console.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apollo-ollama.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError  = logHandle
        }

        // Detach — `setsid` so the child gets its own process
        // group and survives even if Apollo crashes; otherwise
        // the daemon would be reaped along with us.
        var env = ProcessInfo.processInfo.environment

        // ── Resource throttling environment vars ──────────────
        // The default Ollama config is built for "fastest
        // possible inference" — uses every CPU core, keeps the
        // model in RAM for 5 minutes after the last query, and
        // pre-allocates 4 parallel inference slots (= 4×
        // KV-cache memory). Combined with a 7B model on a
        // typical M-series Mac that's >10 GB of pressure, and
        // it makes the entire system feel unresponsive while
        // the AI is "available". The next three vars cut that
        // way back without hurting the actual chat experience.
        //
        //   • OLLAMA_NUM_PARALLEL=1 → single inference slot,
        //     halves the resident memory footprint vs the
        //     default 4 slots.
        //   • OLLAMA_MAX_LOADED_MODELS=1 → don't keep multiple
        //     model variants resident.
        //   • OLLAMA_KEEP_ALIVE=30s → unload the model from
        //     RAM 30 seconds after the last query (default 5m).
        //     If the user keeps chatting it just reloads — but
        //     the moment they idle, the GBs come back to the OS.
        env["OLLAMA_NUM_PARALLEL"]      = "1"
        env["OLLAMA_MAX_LOADED_MODELS"] = "1"
        env["OLLAMA_KEEP_ALIVE"]        = "30s"
        // Cap thread count to ~half the physical cores so the
        // model inference can't starve the rest of the system
        // (Apollo's UI, browser, IDE, etc). On an M2 Pro
        // (10 cores), this leaves 5 cores free at all times
        // for foreground work. We keep at least 4 threads so
        // single-token latency isn't cripplingly slow.
        let physical = ProcessInfo.processInfo.activeProcessorCount
        let threadCap = max(4, physical / 2)
        env["OLLAMA_NUM_THREADS"] = "\(threadCap)"
        process.environment = env

        // Run the daemon at background QoS so the macOS
        // scheduler deprioritizes it when the user is doing
        // anything interactive (typing, scrolling, dragging).
        // .background is the lowest non-utility class and is
        // exactly what's intended for "useful work that should
        // never get in the way".
        process.qualityOfService = .background

        do {
            try process.run()
            spawnedDaemon = process
        } catch {
            NSLog("[Apollo] failed to spawn ollama serve: \(error)")
            return false
        }

        // Poll /api/tags until it responds (or 10s elapse).
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isReachable() { return true }
        }
        return false
    }

    // MARK: - Model discovery

    private func listInstalledModels() async -> [String] {
        var req = URLRequest(url: host.appendingPathComponent("api/tags"))
        req.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    /// Heuristic for picking the FASTEST non-reasoning model
    /// available. Speed-first ordering: 1-3B Llama 3.2 family →
    /// Phi-3 mini → Qwen 2.5 small → Llama 3.1 8B → larger non-
    /// reasoning fallbacks. Models on `avoidedModelTokens`
    /// (qwen3, deepseek-r1, etc.) are filtered out — we'd rather
    /// download `llama3.2:3b` than use a reasoning model that
    /// generates 30s of internal monologue per question.
    private func pickBest(from list: [String]) -> String? {
        let usable = list.filter { !Self.isAvoided($0) }
        let preferred = [
            "llama3.2:3b", "llama3.2:1b", "llama3.2",
            "phi3.5:3.8b", "phi3.5",  "phi3:mini", "phi3",
            "qwen2.5:3b",  "qwen2.5:7b",  "qwen2.5",
            "llama3.1:8b", "llama3.1", "llama3",
            "mistral:7b",  "gemma2:9b", "gemma2",
        ]
        for needle in preferred {
            if let match = usable.first(where: { $0.contains(needle) }) {
                return match
            }
        }
        return usable.first
    }

    // MARK: - Pull (with NDJSON progress)

    /// Streams `POST /api/pull` and decodes the NDJSON progress
    /// stream. Updates `modelStatus = .pulling` on each chunk.
    /// Returns `true` once the daemon emits `status: "success"`.
    private func pullModel(_ name: String) async -> Bool {
        var req = URLRequest(url: host.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["name": name, "stream": true]
        )
        req.timeoutInterval = 600  // 10 min — large models take a while

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return false }

        var lastFraction: Double = 0
        var success = false
        var buffer = ""
        do {
            for try await line in bytes.lines {
                buffer = line
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let status = json["status"] as? String {
                    if status == "success" { success = true; break }

                    let total     = (json["total"]     as? Double) ?? 0
                    let completed = (json["completed"] as? Double) ?? 0
                    let fraction  = total > 0 ? min(1, completed / total) : lastFraction
                    if fraction > 0 { lastFraction = fraction }

                    let stage: String = {
                        if total > 0 {
                            let mb = Int(completed / 1_048_576)
                            let totalMB = Int(total / 1_048_576)
                            return "\(status) · \(mb)/\(totalMB) MB"
                        }
                        return status
                    }()

                    modelStatus = .pulling(name, lastFraction, stage)
                }
            }
        } catch {
            NSLog("[Apollo] ollama pull stream error (last line: \(buffer)): \(error)")
            return false
        }
        return success
    }
}
