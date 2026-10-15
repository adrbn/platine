import CoreImage
import Foundation

/// The room's light, rendered once in Cycles (render/room.py): one plate per framing
/// and keyframe hour, plus a light probe at the record for each. The app cross-fades
/// them through the day, puts the city's photograph behind the window (left transparent
/// in the plates) and draws only what moves on top.
final class PlateLibrary {
    /// Where the photo card sits in each framing (0-1, top-left origin) and the lens blur
    /// at infinity, as a fraction of the frame height: render/out/views.json.
    struct Card: Decodable {
        let rect: [Double]
        let blur: Double
    }
    static let bundled: PlateLibrary? = Bundle.main.url(forResource: "Plates", withExtension: nil).flatMap(PlateLibrary.init)

    let directory: URL
    private var cache: [String: CIImage] = [:]
    private var order: [String] = []
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .cacheIntermediates: false])
    private let cards: [String: Card]
    private var photos: [String: CIImage] = [:]
    var city: CityView? { didSet { photos.removeAll() } }
    /// How blurred the view is, relative to the lens (1): 0 sharp, 2 twice as soft.
    var viewBlur = 1.0 { didSet { if viewBlur != oldValue { photos.removeAll() } } }
    private var maskCache: [String: Masks] = [:]

    /// Red: the glass (where the plate is transparent). Green: the plant, softened and
    /// grown a little so its sway warps the wall around the leaves too. `plant` is the
    /// plant's top and bottom (0-1 from the top of the view).
    struct Masks { let image: CGImage; let plant: (top: Double, bottom: Double)? }

    init?(directory: URL) {
        self.directory = directory
        cards = (try? JSONDecoder().decode([String: Card].self,
                                           from: Data(contentsOf: directory.appendingPathComponent("views.json")))) ?? [:]
        guard Framing.allCases.allSatisfy({ url(for: "\($0.rawValue)-noon") != nil }) else { return nil }
    }

    private func url(for name: String) -> URL? {
        ["heic", "jpg", "png"].lazy.map { self.directory.appendingPathComponent("\(name).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func image(_ name: String) -> CIImage? {
        if let hit = cache[name] { return hit }
        guard let url = url(for: name), let img = CIImage(contentsOf: url) else { return nil }
        cache[name] = img
        order.append(name)
        // ponytail: tiny LRU, four framings x two hours is the most a day needs at once.
        if order.count > 6 { cache[order.removeFirst()] = nil }
        return img
    }

    /// The plate for this framing at this hour, greyed by `overcast` and cropped to fill `aspect`.
    func plate(_ framing: Framing, hour: Double, overcast: Double, aspect: Double) -> CGImage? {
        guard var img = blended(prefix: framing.rawValue, hour: hour) else { return nil }
        if let view = view(framing, hour: hour, extent: img.extent) { img = img.composited(over: view) }
        img = grey(img, overcast: overcast)
        let rect = PlateSchedule.crop(plate: img.extent.size, aspect: aspect)
        return context.createCGImage(img.cropped(to: rect), from: rect)
    }

    func card(_ framing: Framing) -> Card? { cards[framing.rawValue] }

    func masks(_ framing: Framing, aspect: Double) -> Masks? {
        let key = "\(framing.rawValue)|\(Int(aspect * 100))"
        if let hit = maskCache[key] { return hit }
        guard let plate = image("\(framing.rawValue)-noon") else { return nil }
        let extent = plate.extent
        func channel(_ img: CIImage, _ v: CIVector) -> CIImage {
            img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: v.x), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: v.y),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: v.z, y: 0, z: 0, w: 1)])
        }
        var img = channel(plate, CIVector(x: -1, y: 0, z: 1))
        var plantImage: CIImage?
        if let p = image("plant-\(framing.rawValue)") {
            let s = extent.width / p.extent.width
            let px = extent.height / 400
            let green = channel(p.transformed(by: CGAffineTransform(scaleX: s, y: s)), CIVector(x: 0, y: 1, z: 0))
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2 * px])
                .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2 * px])
                .cropped(to: extent)
            plantImage = green
            img = green.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: img])
        }
        let rect = PlateSchedule.crop(plate: extent.size, aspect: aspect)
        guard let cg = context.createCGImage(img.cropped(to: rect), from: rect) else { return nil }
        let masks = Masks(image: cg, plant: plantImage.flatMap { span(of: $0.cropped(to: rect), in: rect) })
        maskCache[key] = masks
        return masks
    }

    /// Top and bottom rows (0-1 from the top) where the green channel shows.
    private func span(of img: CIImage, in rect: CGRect) -> (top: Double, bottom: Double)? {
        let w = 64, h = 64
        let small = img.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(w) / rect.width, y: CGFloat(h) / rect.height)))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: nil)
        // The bitmap comes out top row first.
        let rows = (0..<h).filter { y in (0..<w).contains { px[(y * w + $0) * 4 + 1] > 60 } }
        guard let lo = rows.first, let hi = rows.last else { return nil }
        return (Double(lo) / Double(h), Double(hi + 1) / Double(h))
    }

    /// What the record sees, for reflections and the light on the moving parts.
    func probe(_ framing: Framing, hour: Double, overcast: Double) -> CGImage? {
        guard let img = blended(prefix: "probe-\(framing.rawValue)", hour: hour) else { return nil }
        return context.createCGImage(grey(img, overcast: overcast), from: img.extent)
    }

    /// Average colour of an image, 0…1 per channel.
    func average(_ image: CGImage) -> SIMD3<Double> {
        let ci = CIImage(cgImage: image)
        let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return SIMD3(Double(px[0]), Double(px[1]), Double(px[2])) / 255
    }

    private func blended(prefix: String, hour: Double) -> CIImage? {
        let b = PlateSchedule.blend(atHour: hour)
        guard let from = image("\(prefix)-\(b.from)") ?? image("\(prefix)-\(b.to)") else { return nil }
        var img = from
        if b.t > 0.001, let to = image("\(prefix)-\(b.to)") {
            img = from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: b.t])
        }
        return img
    }

    private func grey(_ image: CIImage, overcast: Double) -> CIImage {
        var img = image
        if overcast > 0.01 {
            // Rain: the sun goes, the colour drains, the room darkens a little.
            let o = min(1, overcast)
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - 0.45 * o,
                                                                    kCIInputContrastKey: 1 - 0.18 * o])
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.45 * o])
        }
        return img
    }

    // MARK: The view

    /// The city's photograph behind this framing, day fading to night with the hour.
    private func view(_ framing: Framing, hour: Double, extent: CGRect) -> CIImage? {
        guard let city, let card = cards[framing.rawValue] else { return nil }
        let mix = PlateSchedule.photo(atHour: hour)
        let day = city.day.flatMap { placed($0, key: "\(framing.rawValue)|day", card: card, extent: extent) }
        var night = city.night.flatMap { placed($0, key: "\(framing.rawValue)|night", card: card, extent: extent) }
        if night == nil, let day {
            // No night photo: the day one, darkened to dusk.
            night = day.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2.6])
        }
        guard var img = day ?? night else { return nil }
        if mix.warmth > 0.01 || mix.ev < -0.01 {
            let w = mix.warmth
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + 0.06 * w, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - 0.12 * w, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.4 * w, w: 0),
            ]).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: mix.ev])
        }
        if let night, mix.night > 0.001 {
            img = mix.night > 0.999 ? night
                : img.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: night, kCIInputTimeKey: mix.night])
        }
        return img.cropped(to: extent)
    }

    /// The photo filling its card, through the lens: rendered once per city and framing.
    private func placed(_ url: URL, key: String, card: Card, extent: CGRect) -> CIImage? {
        if let hit = photos[key] { return hit }
        guard card.rect.count == 4, let photo = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        // A strong blur is computed small and scaled up: same look, a fraction of the time.
        let radius = card.blur * viewBlur * extent.height / 2
        let k = max(1, radius / 8)
        let small = CGRect(x: 0, y: 0, width: (extent.width / k).rounded(.up), height: (extent.height / k).rounded(.up))
        let W = small.width, H = small.height
        // Card in Core Image's bottom-left coordinates.
        let r = CGRect(x: card.rect[0] * W, y: (1 - card.rect[3]) * H,
                       width: (card.rect[2] - card.rect[0]) * W, height: (card.rect[3] - card.rect[1]) * H)
        let p = photo.extent
        let s = max(r.width / p.width, r.height / p.height)
        var img = photo.transformed(by: CGAffineTransform(translationX: -p.minX, y: -p.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: r.midX - p.width * s / 2, y: r.midY - p.height * s / 2)))
            .clampedToExtent()
        if radius > 0.5 {
            img = img.applyingFilter("CIBokehBlur", parameters: [kCIInputRadiusKey: min(radius / k, 120),
                                                                  "inputRingAmount": 0, "inputSoftness": 1])
        }
        guard let cg = context.createCGImage(img.cropped(to: small), from: small) else { return nil }
        let result = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: extent.width / W, y: extent.height / H))
            .samplingLinear().cropped(to: extent)
        photos[key] = result
        return result
    }
}
