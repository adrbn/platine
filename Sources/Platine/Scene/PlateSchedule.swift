import CoreGraphics
import Foundation

/// Which two pre-rendered plates to cross-fade at a given hour. The keyframes
/// are DayCycle's; render/room.py renders one plate per tag.
enum PlateSchedule {
    static let tags = ["night", "dawn", "morning", "noon", "afternoon", "golden", "dusk"]

    static let keys: [(hour: Double, tag: String)] = [
        (0, "night"), (5, "night"), (6.3, "dawn"), (7.5, "morning"), (12, "noon"),
        (16, "afternoon"), (17.6, "golden"), (19, "dusk"), (20.3, "night"),
    ]

    /// The plates either side of `hour` and how far to fade from the first to the second.
    static func blend(atHour hour: Double) -> (from: String, to: String, t: Double) {
        let h = (hour.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
        let next = keys.firstIndex(where: { $0.hour > h }) ?? keys.count
        let a = keys[(next - 1 + keys.count) % keys.count]
        let b = keys[next % keys.count]
        let span = (b.hour - a.hour + 24).truncatingRemainder(dividingBy: 24)
        let into = (h - a.hour + 24).truncatingRemainder(dividingBy: 24)
        let t = span == 0 ? 0 : into / span
        if a.tag == b.tag { return (a.tag, a.tag, 0) }
        return (a.tag, b.tag, t * t * (3 - 2 * t))
    }

    /// How the photo through the window changes with the hour: how far toward the night
    /// photograph, how much the day one is warmed, and how far it is darkened (EV).
    /// Two different photos never sit half-faded for long: the day one dims to dusk
    /// first, then gives way to the night one in about half an hour.
    static let photoKeys: [(hour: Double, night: Double, warmth: Double, ev: Double)] = [
        (0, 1, 0, 0), (5.6, 1, 0, 0), (6.2, 0, 0.5, -1.6), (7.5, 0, 0.3, -0.3), (9, 0, 0, 0),
        (16, 0, 0, 0), (17.6, 0, 0.6, -0.3), (19, 0, 0.7, -1.6), (19.6, 1, 0, 0),
    ]

    static func photo(atHour hour: Double) -> (night: Double, warmth: Double, ev: Double) {
        let h = (hour.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
        let next = photoKeys.firstIndex(where: { $0.hour > h }) ?? photoKeys.count
        let a = photoKeys[(next - 1 + photoKeys.count) % photoKeys.count]
        let b = photoKeys[next % photoKeys.count]
        let span = (b.hour - a.hour + 24).truncatingRemainder(dividingBy: 24)
        let t = span == 0 ? 0 : (h - a.hour + 24).truncatingRemainder(dividingBy: 24) / span
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return (lerp(a.night, b.night), lerp(a.warmth, b.warmth), lerp(a.ev, b.ev))
    }

    /// The centred part of a plate that fills a view of `aspect` (width / height).
    static func crop(plate: CGSize, aspect: Double) -> CGRect {
        let plateAspect = plate.width / plate.height
        if aspect > plateAspect {
            let h = plate.width / aspect
            return CGRect(x: 0, y: (plate.height - h) / 2, width: plate.width, height: h)
        }
        let w = plate.height * aspect
        return CGRect(x: (plate.width - w) / 2, y: 0, width: w, height: plate.height)
    }
}
