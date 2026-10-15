import Combine
import Foundation

/// Rain intensity on the window: 0 none, 1 drizzle, 2 rain, 3 heavy.
@MainActor
final class Weather: ObservableObject {
    static let shared = Weather()

    /// What the forecast says right now (independent of the user's rain setting).
    @Published private(set) var forecastRain = 0
    @Published private(set) var cloudCover = 0.0

    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func start() {
        let settings = Settings.shared
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fetch(settings) }
        }
        settings.$latitude.combineLatest(settings.$longitude)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.fetch(settings) }
            .store(in: &cancellables)
    }

    func rainLevel(for mode: RainMode) -> Int {
        switch mode {
        case .automatic: return forecastRain
        case .drizzle: return 1
        case .rain: return 2
        case .heavy: return 3
        case .off: return 0
        }
    }

    /// Open-Meteo: free, no key, only the city's coordinates leave the Mac.
    private func fetch(_ settings: Settings) {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [.init(name: "latitude", value: String(format: "%.3f", settings.latitude)),
                        .init(name: "longitude", value: String(format: "%.3f", settings.longitude)),
                        .init(name: "current", value: "weather_code,precipitation,cloud_cover")]
        guard let url = c.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else { return }
            let code = current["weather_code"] as? Int ?? 0
            let mm = current["precipitation"] as? Double ?? 0
            let cover = (current["cloud_cover"] as? Double ?? 0) / 100
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.forecastRain = Self.level(code: code, millimetres: mm)
                    self?.cloudCover = cover
                }
            }
        }.resume()
    }

    /// WMO weather codes → drizzle / rain / heavy.
    static func level(code: Int, millimetres: Double) -> Int {
        switch code {
        case 65, 67, 82, 95...99: return 3
        case 61, 63, 66, 80, 81: return millimetres > 4 ? 3 : 2
        case 51...57: return 1
        default: return millimetres > 0.2 ? 1 : 0
        }
    }

    struct Place: Identifiable, Hashable { let id: Int; let name: String; let detail: String; let lat: Double; let lon: Double }

    /// City search for the settings window (Open-Meteo geocoding).
    static func search(_ query: String) async -> [Place] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "6")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let id = r["id"] as? Int, let name = r["name"] as? String,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return Place(id: id, name: name, detail: detail, lat: lat, lon: lon)
        }
    }
}
