import Foundation

/// The real sun where you are. The plates were lit for one fixed day (sunrise at 6:27,
/// sunset at 19:00); today's sunrise, solar noon and sunset are stretched onto it.
enum Sun {
    /// Sunrise, solar noon and sunset as local clock hours; nil in polar day or night.
    /// NOAA's general solar position formula: a minute or two off, plenty for light.
    static func times(on date: Date, latitude: Double, longitude: Double,
                      timeZone: TimeZone = .current) -> (rise: Double, noon: Double, set: Double)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        let g = 2 * Double.pi / 365 * (day - 1)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let lat = latitude * .pi / 180
        let cosH = cos(90.833 * .pi / 180) / (cos(lat) * cos(decl)) - tan(lat) * tan(decl)
        guard abs(cosH) <= 1 else { return nil }
        let halfDay = acos(cosH) * 180 / .pi * 4 / 60
        let noon = (720 - 4 * longitude - eqTime + Double(timeZone.secondsFromGMT(for: date)) / 60) / 60
        return (noon - halfDay, noon, noon + halfDay)
    }

    /// The plate hour for clock hour `h`, given today's sun. Twilight keeps its real length.
    static func plateHour(clock h: Double, rise: Double, noon: Double, set: Double) -> Double {
        let (r, n, s) = (6.45, 12.4, 19.0)
        let p: Double
        if h < rise { p = r - (rise - h) }
        else if h < noon { p = r + (h - rise) / (noon - rise) * (n - r) }
        else if h < set { p = n + (h - noon) / (set - noon) * (s - n) }
        else { p = s + (h - set) }
        return (p + 24).truncatingRemainder(dividingBy: 24)
    }

    static func plateHour(at date: Date, latitude: Double, longitude: Double) -> Double {
        let clock = DayCycle.hour(of: date)
        guard let t = times(on: date, latitude: latitude, longitude: longitude) else { return clock }
        return plateHour(clock: clock, rise: t.rise, noon: t.noon, set: t.set)
    }
}
