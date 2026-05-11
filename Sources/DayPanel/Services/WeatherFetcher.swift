import Foundation
import Combine

/// Tiny weather fetcher used by the clock tile in the AI
/// chat empty state. Hits `wttr.in` (no API key, no auth,
/// geolocates from the user's IP) and exposes the current
/// temperature in °C plus a short condition string.
///
/// Cached for 30 minutes — a chat reopen during that window
/// reuses the previous reading instead of re-fetching. Falls
/// back to `nil` (which the clock tile renders as no temp
/// shown) on any network failure, so the tile never blocks
/// or shows an error UI for a non-essential decoration.
@MainActor
final class WeatherFetcher: ObservableObject {
    static let shared = WeatherFetcher()

    /// Latest reading. Nil until the first successful fetch.
    @Published private(set) var current: Reading?

    struct Reading: Equatable {
        let tempC:    Int
        let city:     String
        let icon:     String   // SF Symbol matching the condition
        let fetched:  Date
    }

    /// 30-minute cache window. Beyond this we hit the network
    /// again on the next `refreshIfStale()`.
    private let cacheLifetime: TimeInterval = 30 * 60
    private var inFlight: Task<Void, Never>?

    private init() {}

    /// Fetches a fresh reading if the cache is empty or
    /// older than `cacheLifetime`. No-op if a fetch is
    /// already running.
    func refreshIfStale() {
        if let r = current,
           Date().timeIntervalSince(r.fetched) < cacheLifetime {
            return
        }
        if inFlight != nil { return }
        inFlight = Task { [weak self] in
            await self?.fetchOnce()
            await MainActor.run { self?.inFlight = nil }
        }
    }

    private func fetchOnce() async {
        guard let url = URL(string: "https://wttr.in/?format=j1") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            // wttr.in's j1 schema:
            //   current_condition: [{ temp_C, weatherDesc, weatherCode }]
            //   nearest_area:      [{ areaName: [{ value }] }]
            let cur = (json["current_condition"] as? [[String: Any]])?.first
            guard let tempStr = cur?["temp_C"] as? String,
                  let tempC = Int(tempStr) else { return }
            let codeStr = cur?["weatherCode"] as? String ?? ""
            let code = Int(codeStr) ?? 0

            var city = "—"
            if let area = (json["nearest_area"] as? [[String: Any]])?.first,
               let nameArr = area["areaName"] as? [[String: Any]],
               let name = nameArr.first?["value"] as? String {
                city = name
            }

            let reading = Reading(
                tempC: tempC,
                city: city,
                icon: Self.symbolForCode(code),
                fetched: Date()
            )
            await MainActor.run { self.current = reading }
        } catch {
            // Silent — the tile just shows no temp on error.
        }
    }

    /// Maps wttr.in's WMO weather codes to SF Symbols. Codes
    /// from https://www.worldweatheronline.com/developer/api/docs/weather-icons.aspx.
    /// We only need a coarse mapping — sun / cloud / rain /
    /// snow / fog — since the tile only shows ONE glyph next
    /// to the temperature.
    private static func symbolForCode(_ code: Int) -> String {
        switch code {
        case 113:                    return "sun.max.fill"           // Clear
        case 116:                    return "cloud.sun.fill"         // Partly cloudy
        case 119, 122:               return "cloud.fill"             // Cloudy / Overcast
        case 143, 248, 260:          return "cloud.fog.fill"         // Mist / Fog
        case 176, 263, 266, 281,
             284, 293, 296, 299,
             302, 305, 308, 311,
             314, 317, 350, 353,
             356, 359, 362, 365,
             368, 392, 395:          return "cloud.rain.fill"        // Rain / Drizzle
        case 179, 227, 230, 320,
             323, 326, 329, 332,
             335, 338, 371, 374,
             377:                    return "snowflake"              // Snow / Sleet
        case 200, 386, 389:          return "cloud.bolt.rain.fill"   // Thunder
        default:                     return "cloud.sun.fill"
        }
    }
}
