import CoreLocation
import Foundation

/// Where the Mac is, roughly, for the sun and the rain. Only asked when you haven't picked
/// a weather city; the coordinates never leave the Mac except to Open-Meteo.
@MainActor
final class Locator: NSObject, CLLocationManagerDelegate {
    static let shared = Locator()
    private let manager = CLLocationManager()

    func start() {
        guard UserDefaults.standard.object(forKey: "cityName") == nil else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        manager.stopUpdatingLocation()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Settings.shared.latitude = c.latitude
                Settings.shared.longitude = c.longitude
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
    }
}
