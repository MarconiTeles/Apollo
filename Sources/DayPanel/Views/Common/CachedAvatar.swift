import SwiftUI
import AppKit

// In-memory cache for ClickUp avatar images. Without this every
// TaskRowView render kicked off a fresh `AsyncImage` fetch + decode for
// the SAME tiny URL — burning CPU/GPU during scroll. NSCache evicts
// under memory pressure automatically.

private final class AvatarStore {
    static let shared = AvatarStore()
    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [NSURL: Task<NSImage?, Never>] = [:]
    private let q = DispatchQueue(label: "AvatarStore", attributes: .concurrent)

    init() {
        cache.countLimit       = 200
        cache.totalCostLimit   = 8 * 1024 * 1024   // ~8 MB of pixel data
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    @discardableResult
    func load(_ url: URL) -> Task<NSImage?, Never> {
        let key = url as NSURL
        if let existing = q.sync(execute: { inFlight[key] }) {
            return existing
        }
        let task = Task<NSImage?, Never> {
            // Already cached? Return immediately.
            if let img = self.cache.object(forKey: key) { return img }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = NSImage(data: data) else { return nil }
                self.cache.setObject(img,
                                     forKey: key,
                                     cost: data.count)
                self.q.async(flags: .barrier) { self.inFlight[key] = nil }
                return img
            } catch {
                self.q.async(flags: .barrier) { self.inFlight[key] = nil }
                return nil
            }
        }
        q.async(flags: .barrier) { self.inFlight[key] = task }
        return task
    }
}

/// Drop-in for `AsyncImage` for avatars. Reads the cache synchronously on
/// first render so already-loaded avatars paint immediately (no fade-in
/// flicker), and falls back to async load + state update for new URLs.
struct CachedAvatar: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard image == nil, let url else { return }
            if let cached = AvatarStore.shared.image(for: url) {
                image = cached
            } else {
                Task {
                    let result = await AvatarStore.shared.load(url).value
                    if let result { await MainActor.run { image = result } }
                }
            }
        }
    }
}
