import AppKit
import CoreGraphics

/// Deterministic noise so the same record always gets the same dust.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    init(_ string: String) { self.init(seed: string.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 }) }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

/// Every texture in the room is drawn here with Core Graphics: no bundled assets.
enum Textures {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()!
    }

    static func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }

    /// Draws attributed text into a CG context (y-up).
    static func text(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .semibold,
                     color: NSColor = .white, serif: Bool = false, centered: Bool = true, tracking: CGFloat = 0,
                     shadow: Bool = false) {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if serif, let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
        if shadow {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.55)
            sh.shadowBlurRadius = size * 0.25
            sh.shadowOffset = .zero
            attrs[.shadow] = sh
        }
        let str = NSAttributedString(string: s, attributes: attrs)
        let bounds = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: CGPoint(x: centered ? p.x - bounds.width / 2 : p.x, y: p.y - bounds.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: The record

    /// Diffuse and specular maps for one side. The specular map marks the
    /// grooves, which catch the light in rings; the lands between songs are glossy.
    static func recordSide(_ side: LPSide?, album: Album?, rpm: Double, size: Int = 2048) -> (diffuse: CGImage, specular: CGImage) {
        let R = LPLayout.recordRadius
        let s = CGFloat(Double(size) / 2 / R)
        let c = CGPoint(x: size / 2, y: size / 2)
        var rnd = SeededRandom("\(album?.key ?? "blank")-\(side?.index ?? 0)")
        // One random sheen value per pixel ring, shared by both maps.
        let ringCount = Int(R * Double(s)) + 2
        let ringNoise = (0..<ringCount).map { _ in rnd.unit() }

        func ring(_ ctx: CGContext, _ r: Double, _ color: CGColor, width: CGFloat = 1.05) {
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: CGRect(x: c.x - CGFloat(r) * s, y: c.y - CGFloat(r) * s,
                                         width: 2 * CGFloat(r) * s, height: 2 * CGFloat(r) * s))
        }
        func disc(_ ctx: CGContext, _ r: Double, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: c.x - CGFloat(r) * s, y: c.y - CGFloat(r) * s,
                                       width: 2 * CGFloat(r) * s, height: 2 * CGFloat(r) * s))
        }
        func grooves(_ ctx: CGContext, from outer: Double, to inner: Double, base: CGFloat, spread: CGFloat) {
            var r = outer
            while r > inner {
                let n = ringNoise[min(ringCount - 1, Int(r * Double(s)))]
                ring(ctx, r, gray(base + spread * n))
                r -= 1 / Double(s)
            }
        }

        let bands = side?.bands ?? []
        let lockGroove = LPLayout.labelRadius + 0.0045

        let diffuse = image(size, size) { ctx in
            disc(ctx, R, gray(0.045))
            disc(ctx, R - 0.0012, gray(0.03))                // raised edge bead
            disc(ctx, LPLayout.leadInRadius + 0.001, gray(0.028))
            for band in bands { grooves(ctx, from: band.outerRadius, to: band.innerRadius, base: 0.03, spread: 0.035) }
            ring(ctx, lockGroove, gray(0.06), width: 1.5)
            // Forty years of dust and handling.
            for _ in 0..<520 {
                let a = rnd.range(0, 2 * .pi), r = sqrt(rnd.unit()) * CGFloat(R - 0.002)
                guard r > CGFloat(LPLayout.labelRadius) else { continue }
                let p = CGPoint(x: c.x + cos(a) * r * s, y: c.y + sin(a) * r * s)
                let d = rnd.range(0.6, 2.2)
                ctx.setFillColor(gray(rnd.range(0.45, 0.8), rnd.range(0.25, 0.7)))
                ctx.fillEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            }
            for _ in 0..<9 {                                   // lint fibres
                let a = rnd.range(0, 2 * .pi), r = rnd.range(CGFloat(LPLayout.labelRadius + 0.01), CGFloat(R - 0.006))
                var p = CGPoint(x: c.x + cos(a) * r * s, y: c.y + sin(a) * r * s)
                ctx.setStrokeColor(gray(0.65, 0.45))
                ctx.setLineWidth(0.8)
                ctx.move(to: p)
                for _ in 0..<5 { p.x += rnd.range(-7, 7); p.y += rnd.range(-7, 7); ctx.addLine(to: p) }
                ctx.strokePath()
            }
            for _ in 0..<7 {                                   // hairline scratches along the groove
                let r = rnd.range(CGFloat(LPLayout.labelRadius + 0.012), CGFloat(R - 0.006)) * s
                let a0 = rnd.range(0, 2 * .pi)
                ctx.setStrokeColor(gray(0.5, 0.12))
                ctx.setLineWidth(0.7)
                ctx.addArc(center: c, radius: r, startAngle: a0, endAngle: a0 + rnd.range(0.2, 0.9), clockwise: false)
                ctx.strokePath()
            }
            drawLabel(ctx, center: c, scale: s, album: album, side: side, rpm: rpm)
        }

        let specular = image(size, size) { ctx in
            disc(ctx, R, gray(0.75))
            disc(ctx, LPLayout.leadInRadius + 0.001, gray(0.95))
            for band in bands { grooves(ctx, from: band.outerRadius, to: band.innerRadius, base: 0.35, spread: 0.55) }
            disc(ctx, LPLayout.labelRadius, gray(0.06))
        }
        return (diffuse, specular)
    }

    private static func drawLabel(_ ctx: CGContext, center c: CGPoint, scale s: CGFloat, album: Album?, side: LPSide?, rpm: Double) {
        let r = CGFloat(LPLayout.labelRadius) * s
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        let art = album?.artwork ?? fallbackCover(title: album?.title ?? "Platine", artist: album?.artist ?? "", size: 512)
        ctx.draw(art, in: aspectFill(CGSize(width: art.width, height: art.height), into: rect))
        // Paper: a soft vignette and a printed rim.
        let grad = CGGradient(colorsSpace: sRGB, colors: [gray(0, 0), gray(0, 0.28)] as CFArray, locations: [0.6, 1])!
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(gray(1, 0.18))
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: rect.insetBy(dx: r * 0.06, dy: r * 0.06))

        let letter = side?.letter ?? "A"
        let speed = rpm > 40 ? "45" : "33⅓"
        text("SIDE \(letter)", in: ctx, at: CGPoint(x: c.x - r * 0.52, y: c.y), size: r * 0.085,
             weight: .bold, tracking: r * 0.012, shadow: true)
        text(speed, in: ctx, at: CGPoint(x: c.x + r * 0.52, y: c.y), size: r * 0.085,
             weight: .bold, tracking: r * 0.006, shadow: true)
        // Spindle hole.
        let h = CGFloat(0.0036) * s
        ctx.setFillColor(gray(0.02))
        ctx.fillEllipse(in: CGRect(x: c.x - h, y: c.y - h, width: 2 * h, height: 2 * h))
    }

    static func aspectFill(_ size: CGSize, into rect: CGRect) -> CGRect {
        let k = max(rect.width / size.width, rect.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// A cover for albums without artwork (and the demo record).
    static func fallbackCover(title: String, artist: String, size: Int = 1024) -> CGImage {
        var rnd = SeededRandom(title + artist)
        let hue = rnd.unit()
        func color(_ h: CGFloat, _ sat: CGFloat, _ b: CGFloat) -> CGColor {
            NSColor(calibratedHue: h.truncatingRemainder(dividingBy: 1), saturation: sat, brightness: b, alpha: 1).cgColor
        }
        return image(size, size) { ctx in
            let S = CGFloat(size)
            ctx.setFillColor(color(hue, 0.35, 0.86))
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
            // A big sun over a horizon, in the spirit of 70s Brazilian sleeves.
            ctx.setFillColor(color(hue + 0.05, 0.75, 0.92))
            ctx.fillEllipse(in: CGRect(x: S * 0.2, y: S * 0.32, width: S * 0.6, height: S * 0.6))
            ctx.setFillColor(color(hue + 0.5, 0.55, 0.42))
            ctx.fill(CGRect(x: 0, y: 0, width: S, height: S * 0.42))
            for i in 0..<6 {
                ctx.setFillColor(color(hue + 0.5, 0.5, 0.36 + CGFloat(i) * 0.03))
                ctx.fill(CGRect(x: 0, y: S * (0.42 - 0.035 * CGFloat(i + 1)), width: S, height: S * 0.012))
            }
            text(title, in: ctx, at: CGPoint(x: S / 2, y: S * 0.2), size: S * 0.075, weight: .regular,
                 color: NSColor(white: 1, alpha: 0.95), serif: true)
            if !artist.isEmpty {
                text(artist.uppercased(), in: ctx, at: CGPoint(x: S / 2, y: S * 0.11), size: S * 0.035,
                     weight: .medium, color: NSColor(white: 1, alpha: 0.85), tracking: S * 0.006)
            }
        }
    }

    // MARK: Turntable

    /// The platter rim: four rows of strobe dots (for 33 and 45 at 50/60 Hz).
    static func strobeRim() -> CGImage {
        image(4096, 160) { ctx in
            ctx.setFillColor(gray(0.78))
            ctx.fill(CGRect(x: 0, y: 0, width: 4096, height: 160))
            var rnd = SeededRandom(seed: 7)
            for _ in 0..<500 {                              // swirl marks on the rim
                ctx.setStrokeColor(gray(rnd.range(0.65, 0.95), 0.25))
                ctx.setLineWidth(0.6)
                let y = rnd.range(0, 160), x = rnd.range(0, 4096)
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + rnd.range(20, 140), y: y + rnd.range(-2, 2)))
                ctx.strokePath()
            }
            let rows: [(count: Int, y: CGFloat)] = [(180, 128), (183, 96), (133, 64), (135, 32)]
            for row in rows {
                let step = 4096 / CGFloat(row.count)
                for i in 0..<row.count {
                    ctx.setFillColor(gray(0.16))
                    ctx.fill(CGRect(x: CGFloat(i) * step + step * 0.25, y: row.y - 9, width: step * 0.5, height: 18))
                }
            }
        }
    }

    static func brushedMetal(base: CGFloat = 0.74) -> CGImage {
        image(1024, 1024) { ctx in
            ctx.setFillColor(gray(base))
            ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            var rnd = SeededRandom(seed: 3)
            for _ in 0..<5000 {
                let y = rnd.range(0, 1024), x = rnd.range(-200, 1024)
                ctx.setStrokeColor(gray(base + rnd.range(-0.08, 0.08), rnd.range(0.15, 0.5)))
                ctx.setLineWidth(rnd.range(0.4, 1.4))
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + rnd.range(80, 600), y: y))
                ctx.strokePath()
            }
        }
    }

    /// Rubber mat with concentric ridges and a little dust in the grooves.
    static func mat() -> CGImage {
        image(1024, 1024) { ctx in
            let c = CGPoint(x: 512, y: 512)
            ctx.setFillColor(gray(0.06))
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            var r: CGFloat = 510
            var odd = false
            while r > 40 {
                ctx.setStrokeColor(gray(odd ? 0.085 : 0.05))
                ctx.setLineWidth(5)
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                r -= 7; odd.toggle()
            }
            var rnd = SeededRandom(seed: 11)
            for _ in 0..<900 {
                let a = rnd.range(0, 2 * .pi), rr = rnd.range(40, 505)
                let d = rnd.range(0.8, 2.4)
                ctx.setFillColor(gray(rnd.range(0.4, 0.7), rnd.range(0.2, 0.5)))
                ctx.fillEllipse(in: CGRect(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr, width: d, height: d))
            }
        }
    }

    // MARK: Room

    static func wood() -> CGImage {
        image(2048, 1024) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.42, green: 0.26, blue: 0.15, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
            var rnd = SeededRandom(seed: 21)
            for i in 0..<700 {
                let y0 = CGFloat(i) * 1024 / 700 + rnd.range(-2, 2)
                let dark = rnd.unit()
                ctx.setStrokeColor(CGColor(srgbRed: 0.30 + 0.16 * dark, green: 0.18 + 0.1 * dark,
                                           blue: 0.10 + 0.05 * dark, alpha: rnd.range(0.25, 0.7)))
                ctx.setLineWidth(rnd.range(0.6, 2.6))
                let phase = rnd.range(0, 6.28), amp = rnd.range(1, 7), freq = rnd.range(0.002, 0.006)
                ctx.move(to: CGPoint(x: 0, y: y0))
                var x: CGFloat = 0
                while x <= 2048 { x += 16; ctx.addLine(to: CGPoint(x: x, y: y0 + amp * sin(x * freq + phase))) }
                ctx.strokePath()
            }
            for _ in 0..<12 {                                  // knots
                let p = CGPoint(x: rnd.range(0, 2048), y: rnd.range(0, 1024))
                for k in 0..<6 {
                    ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.14, blue: 0.08, alpha: 0.35))
                    ctx.setLineWidth(1.5)
                    let w = CGFloat(10 + k * 7)
                    ctx.strokeEllipse(in: CGRect(x: p.x - w * 1.8, y: p.y - w / 2, width: w * 3.6, height: w))
                }
            }
        }
    }

    static func plaster() -> CGImage {
        image(1024, 1024) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.83, blue: 0.78, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            var rnd = SeededRandom(seed: 5)
            for _ in 0..<1400 {
                let d = rnd.range(8, 70)
                ctx.setFillColor(gray(rnd.range(0.7, 1.0), 0.04))
                ctx.fillEllipse(in: CGRect(x: rnd.range(-20, 1024), y: rnd.range(-20, 1024), width: d, height: d))
            }
        }
    }

    /// Vertical sky gradient, top to horizon.
    static func sky(top: SIMD3<Double>, horizon: SIMD3<Double>) -> CGImage {
        image(4, 256) { ctx in
            let colors = [CGColor(srgbRed: top.x, green: top.y, blue: top.z, alpha: 1),
                          CGColor(srgbRed: horizon.x, green: horizon.y, blue: horizon.z, alpha: 1)]
            let g = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 256), end: CGPoint(x: 0, y: 0), options: [])
        }
    }

    /// A dense skyline of towers, in daylight or with its windows lit.
    /// Transparent above the roofs so the sky shows through.
    static func city(night: Bool) -> CGImage {
        let W = 4096, H = 904
        return image(W, H) { ctx in
            var rnd = SeededRandom(seed: 1979)
            // Far, mid and near rows: farther rows are taller on screen, paler and hazier.
            let layers: [(top: CGFloat, low: CGFloat, tone: CGFloat, haze: CGFloat, width: ClosedRange<CGFloat>)] =
                [(0.95, 0.45, 0.72, 0.6, 50...130), (0.7, 0.3, 0.6, 0.35, 60...170), (0.45, 0.15, 0.48, 0.12, 90...240)]
            for (li, layer) in layers.enumerated() {
                var x: CGFloat = -30
                while x < CGFloat(W) {
                    let w = rnd.range(layer.width.lowerBound, layer.width.upperBound)
                    let h = rnd.range(layer.low, layer.top) * CGFloat(H)
                    let t = layer.tone + rnd.range(-0.07, 0.07)
                    let warm = rnd.range(0, 0.06)
                    if night {
                        let k = 0.035 + 0.05 * layer.haze
                        ctx.setFillColor(CGColor(srgbRed: k, green: k * 1.05, blue: k * 1.5, alpha: 1))
                    } else {
                        let k = t + (1 - t) * layer.haze * 0.55
                        ctx.setFillColor(CGColor(srgbRed: k + warm, green: k + warm * 0.6, blue: k - warm * 0.3, alpha: 1))
                    }
                    ctx.fill(CGRect(x: x, y: 0, width: w, height: h))
                    // A darker side face gives each tower some volume.
                    ctx.setFillColor(gray(0, night ? 0.25 : 0.12))
                    ctx.fill(CGRect(x: x + w * 0.78, y: 0, width: w * 0.22, height: h))
                    // Rooftop water tanks and masts.
                    if rnd.unit() < 0.4 {
                        ctx.fill(CGRect(x: x + w * 0.3, y: h, width: w * 0.25, height: 9))
                    }
                    let cols = max(2, Int(w / 12)), cellW = (w - 10) / CGFloat(cols)
                    var y: CGFloat = 8
                    while y < h - 10 {
                        for col in 0..<cols {
                            let cell = CGRect(x: x + 5 + CGFloat(col) * cellW + cellW * 0.2, y: y, width: cellW * 0.6, height: 5)
                            if night {
                                guard rnd.unit() < 0.3 - 0.06 * CGFloat(li) else { continue }
                                let hue = rnd.unit()
                                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.7 + 0.25 * hue, blue: 0.35 + 0.5 * hue,
                                                         alpha: rnd.range(0.5, 1) * (1 - layer.haze * 0.5)))
                            } else {
                                ctx.setFillColor(gray(t * 0.55 + layer.haze * 0.3, 0.8))
                            }
                            ctx.fill(cell)
                        }
                        y += 11
                    }
                    if night && h > CGFloat(H) * 0.62 && rnd.unit() < 0.6 {
                        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.12, blue: 0.08, alpha: 1))
                        ctx.fillEllipse(in: CGRect(x: x + w / 2 - 3, y: h + 2, width: 6, height: 6))
                    }
                    x += w + rnd.range(-14, 4)
                }
            }
        }
    }

    static func softDot(size: Int = 64, alpha: CGFloat = 1, hardness: CGFloat = 0.2) -> CGImage {
        image(size, size) { ctx in
            let c = CGPoint(x: size / 2, y: size / 2)
            let g = CGGradient(colorsSpace: sRGB, colors: [gray(1, alpha), gray(1, alpha * 0.6), gray(1, 0)] as CFArray,
                               locations: [0, hardness, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        }
    }

    /// A raindrop on glass: bright rim, dark core, like a tiny lens.
    static func raindrop() -> CGImage {
        image(64, 64) { ctx in
            let c = CGPoint(x: 32, y: 32)
            let g = CGGradient(colorsSpace: sRGB, colors: [gray(0.15, 0.25), gray(0.5, 0.35), gray(1, 0.9), gray(1, 0)] as CFArray,
                               locations: [0, 0.55, 0.8, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 30, options: [])
            ctx.setFillColor(gray(1, 0.95))
            ctx.fillEllipse(in: CGRect(x: 22, y: 36, width: 8, height: 6))
        }
    }

    static func streak() -> CGImage {
        image(16, 128) { ctx in
            let g = CGGradient(colorsSpace: sRGB, colors: [gray(1, 0), gray(1, 0.5), gray(1, 0)] as CFArray,
                               locations: [0, 0.5, 1])!
            ctx.clip(to: CGRect(x: 6, y: 0, width: 4, height: 128))
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
        }
    }
}
