import Combine
import Foundation

enum Framing: String, CaseIterable, Identifiable, Codable {
    case wide, medium, close, above
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wide: return "Wide"
        case .medium: return "Medium"
        case .close: return "Close"
        case .above: return "From Above"
        }
    }
}

enum RainMode: String, CaseIterable, Identifiable, Codable {
    case automatic, drizzle, rain, heavy, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "From the Forecast"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavy: return "Heavy Rain"
        case .off: return "Off"
        }
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var framing: Framing { didSet { save(framing.rawValue, "framing") } }
    @Published var rainMode: RainMode { didSet { save(rainMode.rawValue, "rainMode") } }
    @Published var cityName: String { didSet { save(cityName, "cityName") } }
    /// The city through the window (CityViews id).
    @Published var viewCity: String { didSet { save(viewCity, "viewCity") } }
    @Published var latitude: Double { didSet { save(latitude, "latitude") } }
    @Published var longitude: Double { didSet { save(longitude, "longitude") } }
    /// Off by default: track lists come from the Music library, offline.
    @Published var catalogLookup: Bool { didSet { save(catalogLookup, "catalogLookup") } }
    @Published var allDisplays: Bool { didSet { save(allDisplays, "allDisplays") } }
    @Published var frameRate: Int { didSet { save(frameRate, "frameRate") } }
    /// How soft the view is, relative to the lens: 0 sharp, 1 as the lens sees it, 2 dreamy.
    @Published var viewBlur: Double { didSet { save(viewBlur, "viewBlur") } }
    /// Fixed hour for the light (nil = follow the clock). Handy to preview.
    @Published var hourOverride: Double? { didSet { save(hourOverride, "hourOverride") } }

    private init() {
        framing = Framing(rawValue: defaults.string(forKey: "framing") ?? "") ?? .wide
        rainMode = RainMode(rawValue: defaults.string(forKey: "rainMode") ?? "") ?? .automatic
        cityName = defaults.string(forKey: "cityName") ?? "Your location"
        viewCity = defaults.string(forKey: "viewCity") ?? CityViews.defaultID
        latitude = defaults.object(forKey: "latitude") as? Double ?? -23.5505
        longitude = defaults.object(forKey: "longitude") as? Double ?? -46.6333
        catalogLookup = defaults.bool(forKey: "catalogLookup")
        allDisplays = defaults.bool(forKey: "allDisplays")
        frameRate = defaults.object(forKey: "frameRate") as? Int ?? 30
        hourOverride = defaults.object(forKey: "hourOverride") as? Double
        viewBlur = defaults.object(forKey: "viewBlur") as? Double ?? 1
    }

    /// The hour the room is lit for: yours, or the real sun's here, stretched onto the plates' day.
    var plateHour: Double { hourOverride ?? Sun.plateHour(at: Date(), latitude: latitude, longitude: longitude) }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
