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

/// A ClickUp user avatar: the profile PHOTO when available, falling back to
/// coloured initials. One component for every "profile circle" in the app.
struct UserAvatar: View {
    let initials: String
    let colorHex: String?
    let photoURL: URL?
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: colorHex ?? "#7A6597"))
            Text(initials)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
            // Photo paints over the initials once loaded; CachedAvatar is
            // transparent until then, so the initials show as the fallback.
            if let photoURL {
                CachedAvatar(url: photoURL)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

extension CUTask.Assignee {
    var photoURL: URL? {
        guard let p = profilePicture, !p.isEmpty else { return nil }
        return URL(string: p)
    }
    /// ClickUp's initials, or derived from the username (first letters of the
    /// first two name tokens) when absent.
    var avatarInitials: String {
        if let i = initials, !i.isEmpty { return i.uppercased() }
        let tokens = username.split(whereSeparator: { " ._-".contains($0) })
        let a = tokens.first?.first.map(String.init) ?? ""
        let b = tokens.dropFirst().first?.first.map(String.init) ?? ""
        let s = (a + b).uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// Overlapping stack of assignee avatars (board cards, etc.). Shows photos with
/// initials fallback, a hairline ring to separate, and a "+N" chip past the cap.
struct AvatarStack: View {
    let assignees: [CUTask.Assignee]
    var size: CGFloat = 22
    var maxShown: Int = 3
    /// Ring colour — should match the card surface behind the stack.
    var ringColor: Color = Editorial.page

    var body: some View {
        let shown = Array(assignees.prefix(maxShown))
        HStack(spacing: -size * 0.34) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, a in
                UserAvatar(initials: a.avatarInitials, colorHex: a.color,
                           photoURL: a.photoURL, size: size)
                    .overlay(Circle().stroke(ringColor, lineWidth: 1.5))
            }
            if assignees.count > maxShown {
                Text("+\(assignees.count - maxShown)")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Editorial.inkSoft)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Editorial.card))
                    .overlay(Circle().stroke(ringColor, lineWidth: 1.5))
            }
        }
    }
}
