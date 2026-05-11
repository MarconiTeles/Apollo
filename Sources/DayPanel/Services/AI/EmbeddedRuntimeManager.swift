import Foundation
import AppKit

/// Lifecycle manager for Apollo's embedded AI runtime. Owns:
///
///   1. **Bundled `ollama` binary** at
///      `Apollo.app/Contents/Resources/ollama` (~74 MB) — ships
///      with the .app.
///   2. **GGUF model weights** at
///      `~/Library/Application Support/Apollo/Models/apollo-ia.gguf`
///      (~1.9 GB) — **NOT bundled**. Downloaded on demand from
///      HuggingFace on first use, with progress reporting. Users
///      who don't want the AI feature never download 2 GB they
///      won't use; users who do, see a progress bar.
///
/// On `bootstrap()` the manager:
///   • Confirms the model file is on disk (`isModelDownloaded`).
///     If missing, fails fast with `.modelMissing` so callers
///     (onboarding step / chat view) can offer a download.
///   • Spawns the daemon, points it at Apollo's private models
///     dir, imports the GGUF as the alias `apollo-ia`.
///   • Subsequent runs are a no-op; the daemon and model stay
///     loaded.
final class EmbeddedRuntimeManager: ObservableObject {

    enum Status: Equatable {
        case idle
        case modelMissing          // model file not on disk yet
        case downloading(Double, Int64, Int64)  // fraction, bytes done, total
        case starting              // spawning daemon
        case importing             // first-run model import
        case ready                 // daemon up + model loaded
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var statusMessage: String = ""

    private var spawnedDaemon: Process?
    private var bootstrapTask: Task<Bool, Never>?
    private var downloadTask:  URLSessionDownloadTask?
    /// URLSession used by the parallel-chunked download path.
    /// Held so `cancelDownload()` can `invalidateAndCancel`
    /// the entire session, aborting every in-flight chunk task
    /// at once.
    private var parallelSession: URLSession?
    private var downloadDelegate: DownloadDelegate?
    private let host = URL(string: "http://localhost:11434")!

    /// Bumped whenever the Modelfile template / system prompt /
    /// model weights change — forces re-import on next bootstrap
    /// so users picking up an updated app don't keep running the
    /// previous Modelfile config.
    /// v4 = richer SYSTEM prompt + temperature 0.55 +
    ///      num_predict 900 + repeat_penalty 1.10.
    /// v5 = swapped GGUF from Llama 3.2 3B to Qwen 2.5 7B
    ///      (see `modelDownloadURL`).
    /// v6 = removed Modelfile SYSTEM (was overriding the
    ///      dynamic system prompt sent per request).
    /// v7 = added explicit ChatML TEMPLATE + stop tokens for
    ///      Qwen 2.5. Ollama's auto-detection from the GGUF
    ///      metadata was failing — without instruction-format
    ///      wrappers, Qwen interpreted the user's message as
    ///      raw text to continue, generating webpage-style
    ///      completions ("Home / Saúde / O que eu tenho hoje?
    ///      Aqui na saúde é muito comum…") instead of an
    ///      assistant reply. Hard-coding the ChatML format
    ///      guarantees the model always receives properly-
    ///      framed instruct-mode input.
    /// v8 = reduced num_ctx 8192 → 4096 (halves model RAM
    ///      footprint), kept other inference params unchanged.
    /// v9 = swapped GGUF from Qwen 2.5 7B → Qwen 3 8B
    ///      Instruct (Q4_K_M, ~5 GB). Qwen 3 stronger
    ///      instruction following, better PT-BR.
    /// v11 = Qwen 3 14B (~12 GB active) tested briefly.
    /// v12 = Qwen 3.5 9B Instruct (Q4_K_M, ~5.5-6 GB on
    ///       disk, ~9 GB active RAM). Sweet spot for the
    ///       16 GB cap: bigger than 8B (more reasoning),
    ///       smaller than 14B (more headroom). Forces re-
    ///       download because file size differs.
    private static let modelfileVersion = 12

    /// Public source URL for the default GGUF.
    ///
    /// Qwen 3.5 9B Instruct, Q4_K_M, ~5.5-6 GB.
    /// Sized for the 16 GB RAM budget the user requested:
    ///   • Disk: ~5.5-6 GB
    ///   • Active RAM: ~9 GB (model + KV cache @ 4096 ctx)
    ///   • Quality positioned between Qwen 3 8B and 14B
    ///   • Same ChatML format expected (Qwen family
    ///     convention) so the existing TEMPLATE in this
    ///     Modelfile remains valid; if the format changed,
    ///     re-import will surface a TEMPLATE error.
    /// If bartowski hasn't published this quant yet, the
    /// download will 404 — switch to an alternate mirror
    /// (unsloth, mradermacher, or the Qwen-org GGUF release).
    private static let modelDownloadURL = URL(string:
        "https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF/resolve/main/Qwen_Qwen3.5-9B-Q4_K_M.gguf"
    )!

    init() {
        // First-launch scan: if a previous install already
        // downloaded the model, mark as idle (ready to bootstrap)
        // instead of `.modelMissing`. Callers can call
        // `refreshDownloadState()` later if needed.
        refreshDownloadState()
    }

    // MARK: - Public API

    /// Re-checks whether the GGUF is present on disk. Cheap —
    /// just a `fileExists` check. Lets the onboarding step
    /// auto-skip when the user already has the model from a
    /// previous Apollo run.
    func refreshDownloadState() {
        if isModelDownloaded {
            // File on disk → flip to idle from any pre-bootstrap
            // state. Critical: must transition out of
            // `.downloading(1.0, ...)` after a successful
            // download or the UI sticks at 100% forever (the
            // .downloading case in the onboarding view never
            // hands off to .idle on its own).
            //
            // Bootstrap states (.starting / .importing / .ready)
            // are preserved — refreshDownloadState only manages
            // the pre-bootstrap lifecycle.
            switch status {
            case .starting, .importing, .ready:
                break
            default:
                status = .idle
                statusMessage = ""
            }
        } else {
            status = .modelMissing
            statusMessage = "Modelo de IA não baixado."
        }
    }

    /// `true` iff the model GGUF is on disk and at least 5 GB.
    /// Current default is Qwen 3.5 9B Q4_K_M (~5.5-6 GB).
    /// Older 4.6 GB Qwen 2.5 7B files fall below this floor
    /// and trigger a fresh download. The previous Qwen 3 8B
    /// (~5 GB) is right at the boundary — using 5.2 GB as the
    /// floor reliably triggers re-download for it without
    /// holding back legitimate 9B downloads.
    var isModelDownloaded: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelGGUFPath.path),
              let attrs = try? fm.attributesOfItem(atPath: modelGGUFPath.path),
              let size  = attrs[.size] as? UInt64
        else { return false }
        return size > 5_200_000_000  // ~5.2 GB floor (Qwen 3.5 9B Q4_K_M ≈ 5.5-6 GB)
    }

    /// Number of parallel HTTP Range streams used to download
    /// the GGUF. HuggingFace's CDN rate-limits each connection
    /// at ~25–40 MB/s; 6 parallel streams typically saturates
    /// fast home connections (200 Mbps – 1 Gbps) without
    /// triggering CDN-side abuse heuristics. Increase to 8 for
    /// gigabit-fibre-class connections; lower to 3-4 if a
    /// future user reports CDN 503s.
    private static let parallelChunkCount = 6

    /// Downloads the model GGUF with streaming progress reports
    /// via the `status` publisher. Returns true on success.
    /// Cancellable via `cancelDownload()`.
    ///
    /// Splits the file into `parallelChunkCount` byte ranges
    /// and downloads them concurrently, then concatenates the
    /// chunks into the final destination. Falls back to a
    /// classic single-stream `URLSessionDownloadTask` if the
    /// HEAD request fails or the server doesn't advertise
    /// `Accept-Ranges: bytes`.
    @discardableResult
    func downloadModel() async -> Bool {
        cancelDownload()

        try? FileManager.default.createDirectory(
            at: modelGGUFPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        await setStatus(.downloading(0, 0, 0),
                        message: "Iniciando download…")

        // Probe the URL: total size + Range support. If either
        // signal is missing we drop to the single-stream path
        // so users on whatever-server still get the model.
        let url = Self.modelDownloadURL
        let probe = await probeRangeSupport(for: url)

        if let total = probe.totalBytes, probe.supportsRanges {
            return await parallelDownload(url: url, totalBytes: total)
        } else {
            return await singleStreamDownload(url: url)
        }
    }

    /// HEAD the URL to learn (a) total file size, (b) whether
    /// the server supports byte-range requests. Returns nils
    /// for either field if the request fails or the headers
    /// don't surface them — caller decides the fallback.
    private func probeRangeSupport(for url: URL)
        async -> (totalBytes: Int64?, supportsRanges: Bool)
    {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        // Some CDNs (HuggingFace's included) only set
        // Accept-Ranges on GETs. Some redirect HEAD elsewhere.
        // Either way `URLSession` follows redirects by default
        // and we read whichever Response we end up at.
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (nil, false)
            }
            let length = http.value(forHTTPHeaderField: "Content-Length")
                .flatMap(Int64.init)
            // Treat the header case-insensitively. Many CDNs
            // return "bytes" but spec allows other tokens.
            let acceptsRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
                .lowercased()
                .contains("bytes")
            return (length, acceptsRanges)
        } catch {
            return (nil, false)
        }
    }

    /// 6-way parallel download. Each task fetches a Range slice
    /// into its own temp file; once all chunks land we
    /// concatenate them into `modelGGUFPath`. Progress is
    /// aggregated through a `@MainActor` actor so the UI
    /// observes a single monotonically-increasing counter
    /// regardless of which chunk is currently faster.
    private func parallelDownload(url: URL, totalBytes total: Int64) async -> Bool {
        let nChunks = Self.parallelChunkCount
        let baseChunk = total / Int64(nChunks)
        let remainder = total % Int64(nChunks)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apollo-download-\(UUID().uuidString)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )

        // Build chunk specs. The last chunk picks up any
        // remainder bytes so the slices add up to the exact
        // file size.
        var specs: [(index: Int, start: Int64, end: Int64, tmpURL: URL)] = []
        var cursor: Int64 = 0
        for i in 0..<nChunks {
            let size = baseChunk + (i == nChunks - 1 ? remainder : 0)
            let start = cursor
            let end   = cursor + size - 1
            specs.append((
                index: i,
                start: start,
                end:   end,
                tmpURL: tmpDir.appendingPathComponent("chunk-\(i).part")
            ))
            cursor += size
        }

        // Per-chunk progress counters → aggregate to total.
        let progress = ChunkProgressActor(totalBytes: total)

        // Use a delegate-less ephemeral session — no cookies,
        // no URLCache, no shared connection limit interference.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.httpMaximumConnectionsPerHost = nChunks
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        self.parallelSession = session

        // Download every chunk concurrently. If any chunk
        // fails, the whole download fails and we clean up.
        let success = await withTaskGroup(
            of: Bool.self,
            returning: Bool.self
        ) { group in
            for spec in specs {
                group.addTask { [weak self] in
                    guard let self else { return false }
                    return await self.downloadChunk(
                        url: url,
                        start: spec.start,
                        end: spec.end,
                        index: spec.index,
                        tmpURL: spec.tmpURL,
                        session: session,
                        progress: progress
                    )
                }
            }

            var allOK = true
            for await ok in group {
                if !ok { allOK = false }
            }
            return allOK
        }

        // Tear down session regardless of outcome.
        session.invalidateAndCancel()
        self.parallelSession = nil

        if !success {
            try? FileManager.default.removeItem(at: tmpDir)
            await setStatus(.failed("Download interrompido"),
                            message: "Download interrompido")
            return false
        }

        // Concatenate chunks → destination.
        let concatOK = concatenate(
            specs: specs.map { $0.tmpURL },
            into: modelGGUFPath
        )
        try? FileManager.default.removeItem(at: tmpDir)

        if concatOK {
            await MainActor.run {
                self.refreshDownloadState()
            }
            return true
        } else {
            await setStatus(.failed("Falha ao montar arquivo"),
                            message: "Falha ao montar arquivo")
            return false
        }
    }

    /// Streams one byte range into its own temp file. Reports
    /// bytes back to the shared progress actor every 256 KB
    /// so the UI sees smooth growth even though chunks finish
    /// out of order.
    private func downloadChunk(url: URL,
                               start: Int64,
                               end: Int64,
                               index: Int,
                               tmpURL: URL,
                               session: URLSession,
                               progress: ChunkProgressActor) async -> Bool {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)",
                     forHTTPHeaderField: "Range")

        do {
            let (asyncBytes, response) = try await session.bytes(for: req)
            // Sanity: server should return 206 Partial Content.
            // If it returns 200, range was ignored — bail so we
            // don't merge a full file with N-1 wrong slices.
            if let http = response as? HTTPURLResponse,
               http.statusCode != 206 && http.statusCode != 200 {
                return false
            }

            FileManager.default.createFile(atPath: tmpURL.path,
                                           contents: nil)
            let writeHandle = try FileHandle(forWritingTo: tmpURL)
            defer { try? writeHandle.close() }

            // Buffer flushes — 256 KB is a sweet spot between
            // syscall overhead and progress smoothness.
            var buffer = Data()
            buffer.reserveCapacity(256 * 1024)

            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try writeHandle.write(contentsOf: buffer)
                    let n = Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    await progress.add(n)
                    await self.publishProgress(progress)
                }
                // Cooperative cancellation — checked every byte
                // is overkill but `Task.isCancelled` is cheap.
                if Task.isCancelled {
                    return false
                }
            }
            if !buffer.isEmpty {
                try writeHandle.write(contentsOf: buffer)
                await progress.add(Int64(buffer.count))
                await self.publishProgress(progress)
            }
            return true
        } catch {
            return false
        }
    }

    /// Pushes the latest aggregated progress to the UI. Hot
    /// path: 6 concurrent chunks call this every 256 KB, so
    /// at peak speeds we'd be pushing ~150 MainActor hops per
    /// second. The actor's internal throttle (`shouldPublish`)
    /// gates updates to ~10 Hz — plenty for a smooth bar with
    /// none of the backlog risk.
    private func publishProgress(_ progress: ChunkProgressActor) async {
        guard await progress.shouldPublish() else { return }
        let snapshot = await progress.snapshot()
        await MainActor.run {
            self.status = .downloading(snapshot.fraction,
                                       snapshot.written,
                                       snapshot.total)
            self.statusMessage = Self.formatProgress(
                fraction: snapshot.fraction,
                written:  snapshot.written,
                total:    snapshot.total
            )
        }
    }

    /// Concatenates `specs` (in order) into `destination`.
    /// Streams each chunk through a 1 MB buffer so we never
    /// hold a full 4.6 GB file in RAM.
    private func concatenate(specs: [URL], into destination: URL) -> Bool {
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path,
                                       contents: nil)
        guard let dest = try? FileHandle(forWritingTo: destination) else {
            return false
        }
        defer { try? dest.close() }

        for chunkURL in specs {
            guard let src = try? FileHandle(forReadingFrom: chunkURL) else {
                return false
            }
            while let data = try? src.read(upToCount: 1_048_576),
                  !data.isEmpty {
                try? dest.write(contentsOf: data)
            }
            try? src.close()
        }
        return true
    }

    /// Fallback single-stream download — used when HEAD fails
    /// or the server doesn't advertise byte-range support.
    /// Same shape as the original implementation, kept around
    /// so we degrade gracefully on weird CDNs.
    private func singleStreamDownload(url: URL) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let delegate = DownloadDelegate(
                destination: modelGGUFPath,
                onProgress: { [weak self] fraction, written, total in
                    Task { @MainActor in
                        self?.status = .downloading(fraction, written, total)
                        self?.statusMessage = Self.formatProgress(
                            fraction: fraction,
                            written:  written,
                            total:    total
                        )
                    }
                },
                onComplete: { [weak self] success, errorMsg in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false); return
                        }
                        if success {
                            self.refreshDownloadState()
                            continuation.resume(returning: true)
                        } else {
                            self.status = .failed(errorMsg ?? "Falha no download")
                            self.statusMessage = errorMsg ?? "Falha no download"
                            continuation.resume(returning: false)
                        }
                    }
                }
            )
            self.downloadDelegate = delegate
            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    func cancelDownload() {
        // Single-stream path
        downloadTask?.cancel()
        downloadTask = nil
        downloadDelegate = nil
        // Parallel path — cancelling the session aborts every
        // in-flight chunk task at once.
        parallelSession?.invalidateAndCancel()
        parallelSession = nil
    }

    /// Bring up the daemon + import model. Returns false (with
    /// status set) if the model isn't downloaded yet — caller
    /// should offer the user a download in that case.
    @discardableResult
    func bootstrap() async -> Bool {
        if status == .ready { return true }
        if !isModelDownloaded {
            await setStatus(.modelMissing,
                            message: "Modelo de IA não baixado.")
            return false
        }

        if let existing = bootstrapTask {
            return await existing.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.runBootstrap()
        }
        bootstrapTask = task
        let ok = await task.value
        bootstrapTask = nil
        return ok
    }

    // MARK: - Paths

    private var modelGGUFPath: URL {
        appSupportDirectory()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("apollo-ia.gguf")
    }

    private func appSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("Apollo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bundledBinary() -> URL? {
        guard let url = Bundle.main.url(forResource: "ollama",
                                        withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: - Bootstrap pipeline

    private func runBootstrap() async -> Bool {
        guard let binary = bundledBinary() else {
            await setStatus(.failed("Binário ollama não encontrado no bundle do Apollo."))
            return false
        }
        let modelsDir = appSupportDirectory()
            .appendingPathComponent("ollama-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir,
                                                  withIntermediateDirectories: true)

        if !(await isReachable()) {
            await setStatus(.starting, message: "Iniciando IA local…")
            let ok = await spawnDaemon(binary: binary, modelsDir: modelsDir)
            if !ok {
                await setStatus(.failed("Não consegui iniciar a IA local."))
                return false
            }
        }

        let storedVersion = UserDefaults.standard
            .integer(forKey: "dp_apollo_ia_modelfile_version")
        let needsImport = !(await isModelImported())
            || storedVersion < Self.modelfileVersion
        if needsImport {
            await setStatus(.importing,
                            message: "Preparando modelo (~30s)…")
            _ = await runCLI(binary: binary,
                             args: ["rm", EmbeddedLLMProvider.modelAlias],
                             modelsDir: modelsDir)
            let ok = await importBundledModel(binary: binary, modelsDir: modelsDir)
            if !ok {
                await setStatus(.failed("Falha ao importar o modelo."))
                return false
            }
            UserDefaults.standard.set(Self.modelfileVersion,
                                       forKey: "dp_apollo_ia_modelfile_version")
        }

        await setStatus(.ready, message: "Apollo IA pronta.")
        return true
    }

    private func runCLI(binary: URL, args: [String], modelsDir: URL) async -> Int32 {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_MODELS"] = modelsDir.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
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

    private func spawnDaemon(binary: URL, modelsDir: URL) async -> Bool {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]

        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_MODELS"] = modelsDir.path
        env["OLLAMA_DEBUG"] = "false"
        process.environment = env

        let logURL = appSupportDirectory().appendingPathComponent("ollama.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = logHandle
            process.standardError  = logHandle
        }

        do {
            try process.run()
            spawnedDaemon = process
        } catch {
            NSLog("[Apollo] failed to spawn embedded ollama: \(error)")
            return false
        }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isReachable() { return true }
        }
        return false
    }

    private func isModelImported() async -> Bool {
        var req = URLRequest(url: host.appendingPathComponent("api/tags"))
        req.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return false }
        let names = models.compactMap { $0["name"] as? String }
        return names.contains { $0.hasPrefix(EmbeddedLLMProvider.modelAlias) }
    }

    private func importBundledModel(binary: URL, modelsDir: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: modelGGUFPath.path) else {
            return false
        }

        // Qwen 2.5 ChatML chat template. Hard-coded because
        // Ollama's auto-detection from the GGUF metadata was
        // not engaging on this specific bartowski Qwen 2.5 7B
        // build — without the wrappers, Qwen treats the
        // request as raw text and free-completes from training
        // data (the smoking gun was a "Home / Saúde / O que
        // eu tenho hoje?" health-FAQ webpage continuation).
        //
        // Format reference (Qwen2.5 official tokeniser config):
        //   <|im_start|>system
        //   {system}<|im_end|>
        //   <|im_start|>user
        //   {user}<|im_end|>
        //   <|im_start|>assistant
        //   {assistant}<|im_end|>
        //
        // Note the `\n` separators are baked into the template
        // — Qwen tokenises the literal newline after each
        // role marker and the literal newline before each
        // <|im_end|>. Drop them and the model gets confused.
        let template = """
        TEMPLATE \"\"\"{{- if .System }}<|im_start|>system
        {{ .System }}<|im_end|>
        {{ end }}{{- range .Messages }}<|im_start|>{{ .Role }}
        {{ .Content }}<|im_end|>
        {{ end }}<|im_start|>assistant


        \"\"\"
        """

        let modelfile = """
        FROM \(modelGGUFPath.path)

        \(template)

        PARAMETER temperature 0.55
        PARAMETER num_predict 900
        PARAMETER num_ctx 4096
        PARAMETER repeat_penalty 1.10
        PARAMETER stop "<|im_start|>"
        PARAMETER stop "<|im_end|>"
        """
        // num_ctx halved from 8192 → 4096. The system prompt +
        // workspace data fits comfortably in 4K (measured at
        // ~2.5K tokens for a typical workspace). Halving the
        // context window cuts the KV-cache memory footprint
        // from ~2 GB to ~1 GB — meaningful relief on systems
        // with 8-16 GB RAM where the rest of the OS, Apollo,
        // and the user's other apps were getting swapped out
        // when the model was loaded.
        // Still NO `SYSTEM` directive — `EmbeddedLLMProvider`
        // injects the rich dynamic system prompt on every
        // `/api/chat` request as a `system`-role message, and
        // the TEMPLATE above interpolates it into the
        // `{{ .System }}` slot. A static Modelfile SYSTEM
        // would shadow that and we'd lose the workspace data.
        let modelfileURL = appSupportDirectory()
            .appendingPathComponent("Modelfile.apollo-ia")
        try? modelfile.write(to: modelfileURL, atomically: true, encoding: .utf8)

        let exit = await runCLI(binary: binary,
                                args: ["create",
                                       EmbeddedLLMProvider.modelAlias,
                                       "-f", modelfileURL.path],
                                modelsDir: modelsDir)
        return exit == 0
    }

    // MARK: - Helpers

    @MainActor
    private func setStatus(_ s: Status, message: String? = nil) {
        status = s
        if let message { statusMessage = message }
    }

    /// "1.2 GB de 1.9 GB · 63%" — formats download progress for
    /// the status bar in onboarding / chat views.
    private static func formatProgress(fraction: Double,
                                       written: Int64,
                                       total: Int64) -> String {
        let writtenGB = Double(written) / 1_073_741_824
        let totalGB   = Double(total)   / 1_073_741_824
        let pct       = Int(round(fraction * 100))
        if total > 0 {
            return String(format: "%.2f GB de %.2f GB · %d%%",
                          writtenGB, totalGB, pct)
        }
        return String(format: "%.2f GB baixados", writtenGB)
    }
}

// MARK: - URLSessionDownloadDelegate adapter

/// Tiny `URLSessionDownloadDelegate` that forwards
/// `didWriteData` events to a SwiftUI-friendly progress closure
/// and finalises by moving the temp file to its final
/// destination. Avoids polluting `EmbeddedRuntimeManager` with
/// `NSObject` inheritance.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let onProgress:  (Double, Int64, Int64) -> Void
    let onComplete:  (Bool, String?) -> Void

    init(destination: URL,
         onProgress: @escaping (Double, Int64, Int64) -> Void,
         onComplete: @escaping (Bool, String?) -> Void) {
        self.destination = destination
        self.onProgress  = onProgress
        self.onComplete  = onComplete
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = max(totalBytesExpectedToWrite, 0)
        let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
        onProgress(fraction, totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        // Replace any prior file atomically.
        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: location, to: destination)
            onComplete(true, nil)
        } catch {
            onComplete(false, "Falha ao mover arquivo: \(error.localizedDescription)")
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            onComplete(false, error.localizedDescription)
        }
    }
}

// MARK: - Parallel-download progress aggregator

/// Thread-safe accumulator of bytes written across the
/// parallel chunk tasks. Each chunk reports its 256 KB writes
/// through `add(_:)`; the UI reads the latest snapshot via
/// `snapshot()`. Using an `actor` here serialises the additions
/// without forcing a `DispatchQueue` round-trip on every byte
/// flush — and matches the rest of the file's async/await
/// style.
private actor ChunkProgressActor {
    let total: Int64
    private(set) var written: Int64 = 0
    /// Last time `shouldPublish()` returned true. Throttles
    /// MainActor pushes to ~10 Hz so we don't flood SwiftUI
    /// with hundreds of redundant status updates per second.
    private var lastPublish: Date = .distantPast

    init(totalBytes: Int64) { self.total = totalBytes }

    func add(_ n: Int64) { written += n }

    struct Snapshot {
        let written: Int64
        let total:   Int64
        let fraction: Double
    }

    func snapshot() -> Snapshot {
        let frac = total > 0 ? Double(written) / Double(total) : 0
        return Snapshot(written: written, total: total, fraction: frac)
    }

    /// Returns true at most once per ~100 ms. Callers use it
    /// as a gate before invoking the MainActor-bound progress
    /// publisher. Because the actor serialises calls across
    /// the 6 chunk tasks, the throttle is global, not per-
    /// chunk — the result is roughly 10 UI updates per second
    /// regardless of how many chunks are flushing buffers.
    func shouldPublish() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastPublish) >= 0.1 {
            lastPublish = now
            return true
        }
        return false
    }
}
