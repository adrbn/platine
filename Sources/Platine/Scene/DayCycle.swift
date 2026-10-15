import Foundation

/// The room's light at one moment of the day. Colours are linear-ish RGB 0…1.
struct DayLight: Equatable {
    var skyTop: SIMD3<Double>
    var skyHorizon: SIMD3<Double>
    var sunColor: SIMD3<Double>
    var sunIntensity: Double      // lumens-ish for SceneKit's directional light
    var sunElevation: Double      // radians above the horizon
    var ambient: Double           // environment light intensity
    var lamp: Double              // the desk lamp, 0 = off
    var cityLights: Double        // lit windows in the skyline, 0…1
    var haze: Double              // how washed out the skyline is, 0…1

    static func mix(_ a: DayLight, _ b: DayLight, _ t: Double) -> DayLight {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        func m3(_ x: SIMD3<Double>, _ y: SIMD3<Double>) -> SIMD3<Double> { x + (y - x) * t }
        return DayLight(skyTop: m3(a.skyTop, b.skyTop), skyHorizon: m3(a.skyHorizon, b.skyHorizon),
                        sunColor: m3(a.sunColor, b.sunColor), sunIntensity: m(a.sunIntensity, b.sunIntensity),
                        sunElevation: m(a.sunElevation, b.sunElevation), ambient: m(a.ambient, b.ambient),
                        lamp: m(a.lamp, b.lamp), cityLights: m(a.cityLights, b.cityLights), haze: m(a.haze, b.haze))
    }

    /// Rain greys the sky, hides the sun and brings the lamp on earlier.
    func overcast(_ amount: Double) -> DayLight {
        guard amount > 0 else { return self }
        let a = min(1, amount)
        func grey(_ c: SIMD3<Double>, _ k: Double) -> SIMD3<Double> {
            let l = (c.x + c.y + c.z) / 3
            return c + (SIMD3(repeating: l * k) - c) * a
        }
        var d = self
        d.skyTop = grey(skyTop, 0.8)
        d.skyHorizon = grey(skyHorizon, 0.85)
        d.sunIntensity = sunIntensity * (1 - 0.8 * a)
        d.ambient = ambient * (1 - 0.3 * a)
        d.lamp = max(lamp, 0.45 * a)
        d.haze = min(1, haze + 0.4 * a)
        return d
    }
}

/// Keyframes through a day; the light is interpolated continuously between them,
/// so it moves with the clock instead of jumping between a few pictures.
enum DayCycle {
    typealias C = SIMD3<Double>

    static let keys: [(hour: Double, light: DayLight)] = [
        (0.0, DayLight(skyTop: C(0.01, 0.015, 0.04), skyHorizon: C(0.20, 0.12, 0.11), sunColor: C(0.5, 0.6, 1.0),
                       sunIntensity: 60, sunElevation: 0.6, ambient: 0.12, lamp: 1, cityLights: 1, haze: 0.2)),
        (5.0, DayLight(skyTop: C(0.02, 0.03, 0.07), skyHorizon: C(0.16, 0.11, 0.12), sunColor: C(0.5, 0.6, 1.0),
                       sunIntensity: 50, sunElevation: 0.3, ambient: 0.14, lamp: 0.9, cityLights: 0.8, haze: 0.3)),
        (6.3, DayLight(skyTop: C(0.18, 0.22, 0.36), skyHorizon: C(0.85, 0.55, 0.42), sunColor: C(1.0, 0.62, 0.38),
                       sunIntensity: 400, sunElevation: 0.05, ambient: 0.35, lamp: 0.4, cityLights: 0.4, haze: 0.75)),
        (7.5, DayLight(skyTop: C(0.42, 0.55, 0.70), skyHorizon: C(0.95, 0.85, 0.72), sunColor: C(1.0, 0.82, 0.62),
                       sunIntensity: 1100, sunElevation: 0.25, ambient: 0.6, lamp: 0, cityLights: 0.05, haze: 0.8)),
        (12.0, DayLight(skyTop: C(0.24, 0.48, 0.86), skyHorizon: C(0.72, 0.84, 0.96), sunColor: C(1.0, 0.97, 0.92),
                        sunIntensity: 1800, sunElevation: 1.05, ambient: 0.95, lamp: 0, cityLights: 0, haze: 0.25)),
        (16.0, DayLight(skyTop: C(0.30, 0.50, 0.80), skyHorizon: C(0.85, 0.82, 0.74), sunColor: C(1.0, 0.88, 0.70),
                        sunIntensity: 1500, sunElevation: 0.55, ambient: 0.8, lamp: 0, cityLights: 0, haze: 0.35)),
        (17.6, DayLight(skyTop: C(0.36, 0.42, 0.62), skyHorizon: C(1.0, 0.70, 0.40), sunColor: C(1.0, 0.66, 0.32),
                        sunIntensity: 1400, sunElevation: 0.18, ambient: 0.6, lamp: 0.1, cityLights: 0.1, haze: 0.55)),
        (19.0, DayLight(skyTop: C(0.14, 0.14, 0.30), skyHorizon: C(0.80, 0.40, 0.30), sunColor: C(1.0, 0.45, 0.25),
                        sunIntensity: 300, sunElevation: 0.02, ambient: 0.3, lamp: 0.6, cityLights: 0.55, haze: 0.5)),
        (20.3, DayLight(skyTop: C(0.03, 0.04, 0.10), skyHorizon: C(0.24, 0.14, 0.13), sunColor: C(0.5, 0.6, 1.0),
                        sunIntensity: 70, sunElevation: 0.4, ambient: 0.15, lamp: 1, cityLights: 1, haze: 0.25)),
    ]

    static func light(atHour hour: Double) -> DayLight {
        let h = (hour.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
        let next = keys.firstIndex(where: { $0.hour > h }) ?? keys.count
        let a = keys[(next - 1 + keys.count) % keys.count]
        let b = keys[next % keys.count]
        let span = (b.hour - a.hour + 24).truncatingRemainder(dividingBy: 24)
        let into = (h - a.hour + 24).truncatingRemainder(dividingBy: 24)
        let t = span == 0 ? 0 : into / span
        // Smoothstep so the light eases through each keyframe.
        return DayLight.mix(a.light, b.light, t * t * (3 - 2 * t))
    }

    /// Sun azimuth across the window: -1 at sunrise (left), +1 at sunset (right).
    static func sunSweep(atHour hour: Double) -> Double {
        min(1, max(-1, (hour - 12.8) / 6.5))
    }

    static func hour(of date: Date, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
    }
}
