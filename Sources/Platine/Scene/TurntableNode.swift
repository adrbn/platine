import SceneKit

/// A 1970s direct-drive automatic turntable, modelled part by part:
/// strobe-dotted platter, S-shaped arm with cue, smoked acrylic lid.
/// Units are metres; the plinth sits on y = 0, centred on the origin.
final class TurntableNode: SCNNode {
    static let footHeight: CGFloat = 0.012
    static let deckY: CGFloat = 0.093
    static let spindleXZ = SIMD2<Double>(-0.045, 0.0)
    static let pivotXZ = SIMD2<Double>(0.165, -0.105)
    static let recordTopY: CGFloat = deckY + 0.0306
    static let armDrop: CGFloat = 0.022

    let geometryModel = TonearmGeometry(spindle: TurntableNode.spindleXZ, pivot: TurntableNode.pivotXZ)

    let platterSpin = SCNNode()
    let recordGroup = SCNNode()
    let recordTop = SCNMaterial()
    let recordBottom = SCNMaterial()
    private let armYaw = SCNNode()
    private let armLift = SCNNode()
    private let lamp33 = SCNMaterial()
    private let lamp45 = SCNMaterial()
    private let strobeLens = SCNMaterial()
    /// The stylus tip, for the close framing's focus.
    let stylus = SCNNode()
    /// What moves or lights up: drawn live over the Cycles plates.
    private(set) var liveNodes: [SCNNode] = []
    /// Surfaces that receive the live parts' shadows over the plates.
    private(set) var shadowCatchers: [SCNNode] = []

    override init() {
        super.init()
        name = "turntable"
        buildPlinth()
        buildPlatter()
        buildArm()
        buildLid()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Materials

    static func pbr(_ color: NSColor, metal: CGFloat = 0, rough: CGFloat = 0.5, texture: Any? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = texture ?? color
        if texture != nil { m.multiply.contents = color }
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }

    private static let aluminium = pbr(.white, metal: 1, rough: 0.3, texture: Textures.brushedMetal())
    private static let chrome = pbr(NSColor(white: 0.9, alpha: 1), metal: 1, rough: 0.2)
    private static let satinBlack = pbr(NSColor(white: 0.07, alpha: 1), metal: 0.2, rough: 0.45)

    private func node(_ g: SCNGeometry, _ m: SCNMaterial, at p: SCNVector3, parent: SCNNode? = nil) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = p
        (parent ?? self).addChildNode(n)
        return n
    }

    // MARK: Plinth

    private func buildPlinth() {
        let f = Self.footHeight
        for (x, z) in [(-0.19, 0.15), (0.19, 0.15), (-0.19, -0.15), (0.19, -0.15)] {
            node(SCNCylinder(radius: 0.028, height: f), Self.satinBlack, at: SCNVector3(x, f / 2, z))
        }
        let body = SCNBox(width: 0.453, height: 0.075, length: 0.367, chamferRadius: 0.005)
        node(body, Self.satinBlack, at: SCNVector3(0, f + 0.0375, 0))
        let plate = SCNBox(width: 0.447, height: 0.006, length: 0.361, chamferRadius: 0.002)
        let top = Self.aluminium.copy() as! SCNMaterial
        top.diffuse.wrapS = .repeat; top.diffuse.wrapT = .repeat
        shadowCatchers.append(node(plate, top, at: SCNVector3(0, Self.deckY - 0.003, 0)))

        // Front controls: start/stop with its print worn by a thumb, speed buttons, lamps.
        let worn = Self.pbr(NSColor(white: 0.62, alpha: 1), metal: 1, rough: 0.5)
        node(SCNBox(width: 0.052, height: 0.006, length: 0.022, chamferRadius: 0.002), worn,
             at: SCNVector3(-0.17, Self.deckY + 0.002, 0.162))
        for (i, x) in [0.10, 0.135].enumerated() {
            node(SCNBox(width: 0.026, height: 0.005, length: 0.016, chamferRadius: 0.002), Self.chrome,
                 at: SCNVector3(x, Self.deckY + 0.0015, 0.162))
            let lamp = i == 0 ? lamp33 : lamp45
            lamp.lightingModel = .constant
            lamp.diffuse.contents = NSColor(red: 0.25, green: 0.08, blue: 0.03, alpha: 1)
            liveNodes.append(node(SCNBox(width: 0.008, height: 0.002, length: 0.004, chamferRadius: 0.001), lamp,
                                  at: SCNVector3(x, Self.deckY + 0.004, 0.148)))
        }
        // Strobe illuminator: lights the dots on the platter rim.
        let housing = node(SCNBox(width: 0.02, height: 0.016, length: 0.02, chamferRadius: 0.003), Self.satinBlack,
                           at: SCNVector3(-0.2, Self.deckY + 0.008, 0.155))
        strobeLens.lightingModel = .constant
        strobeLens.diffuse.contents = NSColor(red: 0.2, green: 0.05, blue: 0.02, alpha: 1)
        let lens = node(SCNBox(width: 0.008, height: 0.008, length: 0.002, chamferRadius: 0.001), strobeLens,
                        at: SCNVector3(0.0101, 0.002, -0.002), parent: housing)
        lens.eulerAngles.y = .pi / 2
        liveNodes.append(lens)
    }

    // MARK: Platter and record

    private func buildPlatter() {
        let s = Self.spindleXZ
        platterSpin.position = SCNVector3(s.x, 0, s.y)
        addChildNode(platterSpin)

        let platter = SCNCylinder(radius: 0.156, height: 0.024)
        platter.radialSegmentCount = 160
        let rim = Self.pbr(.white, metal: 1, rough: 0.28, texture: Textures.strobeRim())
        platter.materials = [rim, Self.aluminium, Self.aluminium]
        let p = SCNNode(geometry: platter)
        p.position = SCNVector3(0, Self.deckY + 0.014, 0)
        platterSpin.addChildNode(p)

        let mat = SCNCylinder(radius: 0.150, height: 0.003)
        mat.radialSegmentCount = 160
        let rubber = Self.pbr(.white, rough: 0.9, texture: Textures.mat())
        mat.materials = [Self.pbr(NSColor(white: 0.05, alpha: 1), rough: 0.9), rubber, rubber]
        let mn = SCNNode(geometry: mat)
        mn.position = SCNVector3(0, Self.deckY + 0.0275, 0)
        platterSpin.addChildNode(mn)
        shadowCatchers.append(mn)

        recordGroup.position = SCNVector3(0, Self.recordTopY - 0.0008, 0)
        platterSpin.addChildNode(recordGroup)
        liveNodes.append(recordGroup)
        // Its caps sit well under the printed faces: coplanar caps fight in the depth buffer at the rim.
        let body = SCNCylinder(radius: LPLayout.recordRadius, height: 0.0011)
        body.radialSegmentCount = 180
        let edge = Self.pbr(NSColor(white: 0.03, alpha: 1), rough: 0.25)
        body.materials = [edge]
        recordGroup.addChildNode(SCNNode(geometry: body))

        for (material, up) in [(recordTop, true), (recordBottom, false)] {
            Self.configureVinyl(material)
            let face = SCNNode(geometry: Self.disc(radius: LPLayout.recordRadius, up: up))
            face.geometry?.materials = [material]
            face.position = SCNVector3(0, up ? 0.00085 : -0.00085, 0)
            recordGroup.addChildNode(face)
        }

        let spindle = SCNCylinder(radius: 0.0036, height: 0.02)
        let sn = node(spindle, Self.chrome, at: SCNVector3(0, Self.recordTopY + 0.002, 0), parent: platterSpin)
        sn.addChildNode(SCNNode(geometry: { let g = SCNSphere(radius: 0.0036); g.materials = [Self.chrome]; return g }()))
        sn.childNodes.last?.position = SCNVector3(0, 0.01, 0)
        liveNodes.append(sn)
    }

    /// Vinyl uses a custom light model: Kajiya-Kay highlights along the grooves,
    /// the radial streak a real record throws back at a lamp.
    static func configureVinyl(_ m: SCNMaterial) {
        m.lightingModel = .blinn
        m.diffuse.contents = NSColor(white: 0.05, alpha: 1)
        m.specular.contents = NSColor(white: 0.6, alpha: 1)
        m.shininess = 0.25
        // The grooves are finer than a pixel at a glancing angle: filter them, don't sample them.
        for p in [m.diffuse, m.specular] {
            p.mipFilter = .linear
            p.maxAnisotropy = 16
        }
        m.setValue(SCNVector3(0, 0, -1), forKey: "recordCenter")
        m.shaderModifiers = [.lightingModel: """
        #pragma arguments
        float3 recordCenter;
        #pragma body
        float3 N = normalize(_surface.normal);
        float3 L = normalize(_light.direction);
        float3 V = normalize(_surface.view);
        float3 H = normalize(L + V);
        float NdotL = max(0.0, dot(N, L));
        float3 d = _surface.position - recordCenter;
        d = d - dot(d, N) * N;
        float3 T = normalize(cross(N, normalize(d + float3(0.00001))));
        float th = dot(T, H);
        float aniso = pow(max(0.0, sqrt(max(0.0, 1.0 - th * th))), 90.0);
        float spec = pow(max(0.0, dot(N, H)), 60.0) * 0.35;
        _lightingContribution.diffuse += _light.intensity.rgb * NdotL;
        _lightingContribution.specular += _light.intensity.rgb * (aniso * 0.9 + spec) * NdotL;
        """]
    }

    /// A flat disc with planar UVs: u follows +x, v follows +z, so a cover drawn
    /// upright in the texture reads upright from the front of the turntable.
    static func disc(radius: CGFloat, up: Bool, segments: Int = 256) -> SCNGeometry {
        var verts = [SCNVector3(0, 0, 0)]
        var uvs = [CGPoint(x: 0.5, y: 0.5)]
        for i in 0...segments {
            let a = CGFloat(i) / CGFloat(segments) * 2 * .pi
            let x = cos(a) * radius, z = sin(a) * radius
            verts.append(SCNVector3(x, 0, z))
            // The underside's v is mirrored so, once flipped over x, it reads exactly like the top.
            uvs.append(CGPoint(x: 0.5 + x / (2 * radius), y: 0.5 + (up ? z : -z) / (2 * radius)))
        }
        let normals = Array(repeating: SCNVector3(0, up ? 1 : -1, 0), count: verts.count)
        var idx: [Int32] = []
        for i in 1...Int32(segments) { idx += up ? [0, i + 1, i] : [0, i, i + 1] }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals),
                                     SCNGeometrySource(textureCoordinates: uvs)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    // MARK: Tonearm

    private func buildArm() {
        let P = Self.pivotXZ
        let L = CGFloat(geometryModel.effectiveLength)
        let armY = Self.recordTopY + Self.armDrop

        node(SCNCylinder(radius: 0.032, height: 0.008), Self.aluminium, at: SCNVector3(P.x, Self.deckY + 0.004, P.y))
        node(SCNCylinder(radius: 0.011, height: armY - Self.deckY), Self.chrome,
             at: SCNVector3(P.x, (armY + Self.deckY) / 2, P.y))

        armYaw.position = SCNVector3(P.x, armY, P.y)
        addChildNode(armYaw)
        liveNodes.append(armYaw)
        armYaw.addChildNode(armLift)
        node(SCNBox(width: 0.022, height: 0.016, length: 0.02, chamferRadius: 0.004), Self.satinBlack,
             at: SCNVector3(0, 0, 0), parent: armLift)

        // S-shaped tube, stub included: one sine period, so the headshell ends back on the arm's axis.
        // One swept mesh with smooth normals, so the chrome reads as one bent tube.
        let tubeEnd = Double(L) - 0.048
        let path = (0...96).map { i -> SIMD2<Double> in
            let x = -0.06 + Double(i) / 96 * (tubeEnd + 0.06)
            return SIMD2(x, x > 0 ? -0.016 * sin(2 * .pi * x / tubeEnd) : 0)
        }
        armLift.addChildNode(SCNNode(geometry: Self.tube(path, radius: 0.0042, material: Self.chrome)))
        // The collar the tube plugs into, on top of the headshell.
        node(SCNBox(width: 0.014, height: 0.011, length: 0.011, chamferRadius: 0.002), Self.satinBlack,
             at: SCNVector3(CGFloat(tubeEnd) + 0.001, -0.0005, 0), parent: armLift)
        let weight = SCNTube(innerRadius: 0.0045, outerRadius: 0.017, height: 0.032)
        weight.materials = [Self.pbr(NSColor(white: 0.55, alpha: 1), metal: 1, rough: 0.35)]
        let wn = SCNNode(geometry: weight)
        wn.position = SCNVector3(-0.068, 0, 0)
        wn.eulerAngles.z = .pi / 2
        armLift.addChildNode(wn)

        // Headshell, cartridge and the stylus at exactly (L, -drop, 0).
        let shell = SCNBox(width: 0.052, height: 0.004, length: 0.019, chamferRadius: 0.0015)
        let sh = node(shell, Self.satinBlack, at: SCNVector3(L - 0.024, -0.002, 0), parent: armLift)
        sh.eulerAngles.y = -0.08
        let cart = SCNBox(width: 0.018, height: 0.014, length: 0.015, chamferRadius: 0.0015)
        node(cart, Self.pbr(NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1), rough: 0.4),
             at: SCNVector3(L - 0.006, -0.011, 0), parent: armLift)
        armLift.addChildNode(Self.segment(from: SCNVector3(L - 0.003, -0.016, 0), to: SCNVector3(L, -Self.armDrop, 0),
                                          radius: 0.0005, material: Self.chrome))
        stylus.position = SCNVector3(L, -Self.armDrop, 0)
        armLift.addChildNode(stylus)
        armLift.addChildNode(Self.segment(from: SCNVector3(L - 0.02, -0.002, 0.009), to: SCNVector3(L - 0.004, 0.004, 0.026),
                                          radius: 0.0011, material: Self.chrome))   // finger lift

        // Arm rest under the tube, and the cue lever beside the pivot.
        let restYaw = geometryModel.restYaw
        let restAt = P + 0.6 * Double(L) * SIMD2(cos(restYaw), -sin(restYaw))
        node(SCNCylinder(radius: 0.004, height: armY - Self.deckY - 0.004), Self.satinBlack,
             at: SCNVector3(restAt.x, (armY - 0.004 + Self.deckY) / 2, restAt.y))
        node(SCNBox(width: 0.014, height: 0.004, length: 0.008, chamferRadius: 0.001), Self.satinBlack,
             at: SCNVector3(restAt.x, armY - 0.006, restAt.y))
        let lever = node(SCNBox(width: 0.006, height: 0.012, length: 0.03, chamferRadius: 0.002), Self.chrome,
                         at: SCNVector3(P.x + 0.045, Self.deckY + 0.008, P.y + 0.11))
        lever.eulerAngles.x = -0.3
    }

    /// A round tube swept along a path in the arm's horizontal plane (x, z).
    static func tube(_ path: [SIMD2<Double>], radius: Double, material: SCNMaterial, sides: Int = 24) -> SCNGeometry {
        var verts: [SCNVector3] = [], normals: [SCNVector3] = [], idx: [Int32] = []
        for (i, p) in path.enumerated() {
            let a = path[max(0, i - 1)], b = path[min(path.count - 1, i + 1)]
            let t = simd_normalize(b - a)
            let side = SIMD2(-t.y, t.x)          // in-plane normal; the other axis is straight up
            for k in 0..<sides {
                let an = Double(k) / Double(sides) * 2 * .pi
                let n = SIMD3(side.x * cos(an), sin(an), side.y * cos(an))
                normals.append(SCNVector3(n.x, n.y, n.z))
                verts.append(SCNVector3(p.x + radius * n.x, radius * n.y, p.y + radius * n.z))
            }
        }
        let S = Int32(sides)
        for i in 0..<Int32(path.count - 1) {
            for k in 0..<S {
                let a = i * S + k, b = i * S + (k + 1) % S, c = a + S, d = b + S
                idx += [a, c, b, b, c, d]
            }
        }
        // Closed ends: flat caps facing out along the path.
        for (end, ring, sign) in [(path[0], Int32(0), -1.0), (path[path.count - 1], Int32(path.count - 1) * S, 1.0)] {
            let a = sign < 0 ? path[1] : path[path.count - 2]
            let out = simd_normalize(end - a)
            let n = SCNVector3(out.x, 0, out.y), base = Int32(verts.count)
            for k in 0..<sides { verts.append(verts[Int(ring) + k]); normals.append(n) }
            verts.append(SCNVector3(end.x, 0, end.y)); normals.append(n)
            let c = base + S
            for k in 0..<S { idx += sign > 0 ? [c, base + k, base + (k + 1) % S] : [c, base + (k + 1) % S, base + k] }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }

    static func segment(from a: SCNVector3, to b: SCNVector3, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = sqrt(dx * dx + dy * dy + dz * dz)
        let c = SCNCylinder(radius: radius, height: len)
        c.radialSegmentCount = 16
        c.materials = [material]
        let n = SCNNode(geometry: c)
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        // Cylinders run along +y; aim that axis from a to b.
        n.look(at: SCNVector3(b.x, b.y, b.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        if abs(dy) > 0.999 * len { n.eulerAngles = SCNVector3(0, 0, 0) }
        return n
    }

    // MARK: Lid

    private func buildLid() {
        let smoked = SCNMaterial()
        smoked.lightingModel = .physicallyBased
        smoked.diffuse.contents = NSColor(red: 0.06, green: 0.055, blue: 0.05, alpha: 1)
        smoked.roughness.contents = 0.06
        smoked.metalness.contents = 0.0
        smoked.isDoubleSided = true
        smoked.writesToDepthBuffer = false

        let hinge = SCNNode()
        hinge.position = SCNVector3(0, Self.deckY, -0.18)
        hinge.eulerAngles.x = -1.62
        addChildNode(hinge)
        let w: CGFloat = 0.448, h: CGFloat = 0.095, d: CGFloat = 0.362
        let panels: [(SCNGeometry, SCNVector3, SCNVector3)] = [
            (SCNPlane(width: w, height: d), SCNVector3(0, h, d / 2), SCNVector3(-CGFloat.pi / 2, 0, 0)),
            (SCNPlane(width: w, height: h), SCNVector3(0, h / 2, d), SCNVector3(0, 0, 0)),
            (SCNPlane(width: w, height: h), SCNVector3(0, h / 2, 0), SCNVector3(0, 0, 0)),
            (SCNPlane(width: d, height: h), SCNVector3(-w / 2, h / 2, d / 2), SCNVector3(0, CGFloat.pi / 2, 0)),
            (SCNPlane(width: d, height: h), SCNVector3(w / 2, h / 2, d / 2), SCNVector3(0, CGFloat.pi / 2, 0)),
        ]
        for (g, p, e) in panels {
            g.materials = [smoked]
            let n = SCNNode(geometry: g)
            n.position = p
            n.eulerAngles = e
            n.renderingOrder = 10
            n.opacity = 0.5
            hinge.addChildNode(n)
        }
        for x in [-0.15, 0.15] {
            node(SCNBox(width: 0.03, height: 0.012, length: 0.014, chamferRadius: 0.002), Self.satinBlack,
                 at: SCNVector3(x, Self.deckY + 0.004, -0.178))
        }
    }

    // MARK: Per frame

    /// The vinyl shader needs the spindle in view space to orient its highlights.
    func updateVinylCenter(camera: SCNNode) {
        let world = simdConvertPosition(SIMD3<Float>(Float(Self.spindleXZ.x), Float(Self.recordTopY), Float(Self.spindleXZ.y)), to: nil)
        let v = camera.presentation.simdWorldTransform.inverse * SIMD4<Float>(world, 1)
        let value = SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
        recordTop.setValue(value, forKey: "recordCenter")
        recordBottom.setValue(value, forKey: "recordCenter")
    }

    func apply(_ m: TurntableMotion, rpm: Double) {
        platterSpin.eulerAngles.y = CGFloat(-m.platterAngle)
        armYaw.eulerAngles.y = CGFloat(m.yaw)
        armLift.eulerAngles.z = CGFloat(m.lift * 0.045)
        let lit = m.platterSpeed > 0.05 ? (rpm > 40 ? 45 : 33) : 0
        guard lit != litLamp else { return }
        litLamp = lit
        let on = NSColor(red: 2.2, green: 0.6, blue: 0.15, alpha: 1)
        let off = NSColor(red: 0.25, green: 0.08, blue: 0.03, alpha: 1)
        lamp33.diffuse.contents = lit == 33 ? on : off
        lamp45.diffuse.contents = lit == 45 ? on : off
        strobeLens.diffuse.contents = lit > 0 ? NSColor(red: 3, green: 0.9, blue: 0.3, alpha: 1) : off
    }

    private var litLamp = -1
}
