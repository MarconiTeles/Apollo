import Foundation

final class CacheManager {
    private var url: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("DayPanel")
            .appendingPathComponent("cache.json")
    }

    func load() -> AppCache? {
        guard let url,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppCache.self, from: data)
    }

    func save(_ cache: AppCache) {
        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
