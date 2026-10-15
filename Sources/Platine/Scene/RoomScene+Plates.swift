import SceneKit

struct PlateState {
    var library: PlateLibrary?
    var aspect = 16.0 / 10
    var lastKey = ""
    /// Materials that take their light from the plate under them (the sleeve covers).
    var litByPlate: [SCNMaterial] = []
    /// The plate itself, drawn on a screen-filling card so a shader can work on it:
    /// drops on the glass, the plant in a breeze.
    let effects = SCNNode(geometry: SCNPlane(width: 1, height: 1))
    var rain = 0.0
}

/// Plate mode: the Cycles render is the background, the SceneKit room stays
/// only as invisible depth (so steam goes behind the mug and rain behind the
/// window bars), and the parts that move are drawn live over it.
extension RoomScene {
    func usePlates(_ library: PlateLibrary) {
        plateState.library = library
        let live = Set(liveNodes + turntable.liveNodes)
        let catchers = Set(turntable.shadowCatchers)
        func isLive(_ node: SCNNode) -> Bool {
            var n: SCNNode? = node
            while let c = n { if live.contains(c) { return true }; n = c.parent }
            return false
        }
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry, !isLive(node) else { return }
            node.geometry = geometry.copy() as? SCNGeometry
            node.geometry?.materials = geometry.materials.map { original in
                if original === pileTop { return original }      // the cover on the pile stays visible
                let m = original.copy() as! SCNMaterial
                if catchers.contains(node) {
                    m.lightingModel = .shadowOnly
                } else {
                    m.colorBufferWriteMask = []
                }
                return m
            }
            node.castsShadow = false
        }
        for n in outsideNodes { n.isHidden = true }
        // Rain is drawn by the plate's shader, on the real glass: the particles go.
        for p in [glassRain, glassBeads, outsideRain] { p.birthRate = 0 }
        liveNodes.filter { $0.particleSystems?.contains { $0 === glassRain || $0 === outsideRain } ?? false }
            .forEach { $0.isHidden = true }
        let fx = SCNMaterial()
        fx.lightingModel = .constant
        fx.readsFromDepthBuffer = false
        fx.writesToDepthBuffer = false
        fx.shaderModifiers = [.fragment: Self.effectsModifier]
        plateState.effects.geometry?.materials = [fx]
        plateState.effects.renderingOrder = -1000
        plateState.effects.castsShadow = false
        plateState.effects.position = SCNVector3(0, 0, -10)
        cameraNode.addChildNode(plateState.effects)
        scene.rootNode.childNode(withName: "glass", recursively: true)?.isHidden = true

        // Covers: the plate rendered white paper where they sit; multiply the art by it.
        plateState.litByPlate = sleeveFaces.compactMap { $0.geometry?.firstMaterial } + [pileTop]
        for m in plateState.litByPlate {
            m.lightingModel = .constant
            m.shaderModifiers = [.fragment: Self.plateLightModifier]
        }

        // The camera's own effects would double what Cycles already did.
        camera.screenSpaceAmbientOcclusionIntensity = 0
        camera.wantsDepthOfField = false
        camera.bloomIntensity = 0
        camera.vignettingIntensity = 0
        camera.exposureOffset = 0
        camera.contrast = 0
        camera.saturation = 1
        camera.wantsExposureAdaptation = false
        camera.minimumExposure = 0
        camera.maximumExposure = 0

        // Light for the live parts: the probe for reflections, a soft key from the window,
        // and a light from above that only the catchers see, for the arm's shadow.
        sun.castsShadow = false
        bounce.intensity = 0
        skyFill.castsShadow = false
        shadowLight.type = .directional
        shadowLight.castsShadow = true
        shadowLight.shadowMode = .forward
        shadowLight.shadowRadius = 12
        shadowLight.shadowSampleCount = 16
        shadowLight.shadowMapSize = CGSize(width: 2048, height: 2048)
        shadowLight.shadowColor = NSColor(white: 0, alpha: 0.45)
        shadowLight.orthographicScale = 0.4
        shadowLight.automaticallyAdjustsShadowProjection = true
        shadowLight.categoryBitMask = 1 << 3
        shadowLight.intensity = 1000
        let sn = SCNNode()
        sn.light = shadowLight
        sn.position = SCNVector3(0.05, 1.2, 0.2)
        sn.look(at: SCNVector3(-0.02, 0, -0.03))
        scene.rootNode.addChildNode(sn)
        for c in catchers { c.categoryBitMask |= 1 << 3 }
        for l in [sun, skyFill, bounce, lamp] { l.categoryBitMask = 1 }
        setFraming(framing, animated: false)
    }

    var usesPlates: Bool { plateState.library != nil }

    /// The city behind the window; takes effect on the next updateEnvironment.
    func setCity(_ city: CityView?) {
        plateState.library?.city = city
        plateState.lastKey = ""
    }

    /// The plate's camera: exact, with the field of view narrowed when the view is wider than the plate.
    func applyPlateCamera() {
        let s = Self.shot(framing)
        // A cut, never a move: the plate behind changes in one frame, so must the camera.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        SCNTransaction.disableActions = true
        cameraNode.removeAllAnimations()
        cameraNode.position = s.position
        cameraNode.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)   // look(at:) is relative: from above it drifts
        cameraNode.look(at: s.target)
        defer { SCNTransaction.commit() }
        let plateAspect = 16.0 / 10
        let a = plateState.aspect
        var fov = Double(s.fov)
        if a > plateAspect {
            fov = 2 * atan(tan(fov * .pi / 360) * plateAspect / a) * 180 / .pi
        }
        camera.projectionDirection = .vertical
        camera.fieldOfView = CGFloat(fov)
        // The same lens as the plate (render/room.py set_shot): Blender's 36 mm sensor, fitted
        // to a 16:10 frame, focused on the stylus.
        camera.sensorHeight = 36 * 10 / 16
        // The effects card fills the frame exactly, 10 m out.
        let h = 2 * 10 * tan(fov * .pi / 360)
        (plateState.effects.geometry as? SCNPlane)?.height = CGFloat(h)
        (plateState.effects.geometry as? SCNPlane)?.width = CGFloat(h * a)
        camera.wantsDepthOfField = s.fStop > 0
        if s.fStop > 0 {
            camera.fStop = s.fStop
            camera.focalBlurSampleCount = 16
            let focus = SIMD3(TurntableNode.spindleXZ.x, Double(TurntableNode.recordTopY), TurntableNode.spindleXZ.y + 0.05)
            camera.focusDistance = CGFloat(simd_distance(focus, SIMD3(Double(s.position.x), Double(s.position.y), Double(s.position.z))))
        }
    }

    func updatePlates(hour: Double, overcast: Double, lamp lampLevel: Double) {
        guard let library = plateState.library else { return }
        let key = "\(framing.rawValue)|\(Int(hour * 60))|\(Int(overcast * 20))|\(Int(plateState.aspect * 100))"
        guard key != plateState.lastKey else { return }
        plateState.lastKey = key
        guard let plate = library.plate(framing, hour: hour, overcast: overcast, aspect: plateState.aspect),
              let probe = library.probe(framing, hour: hour, overcast: overcast) else { return }
        scene.background.contents = plate
        if let fx = plateState.effects.geometry?.firstMaterial {
            let tex = SCNMaterialProperty(contents: plate)
            tex.mipFilter = .linear
            fx.setValue(tex, forKey: "plateTex")
            if let masks = library.masks(framing, aspect: plateState.aspect) {
                fx.setValue(SCNMaterialProperty(contents: masks.image), forKey: "maskTex")
                let p = masks.plant ?? (0, 0)
                fx.setValue(NSValue(scnVector4: SCNVector4(p.top, p.bottom, masks.plant == nil ? 0 : 0.0022, 0)), forKey: "plant")
            }
            fx.setValue(Float(plateState.aspect), forKey: "aspect")
            fx.setValue(Float(glassBlur(library)), forKey: "glassBlur")
        }
        for m in plateState.litByPlate { m.setValue(SCNMaterialProperty(contents: plate), forKey: "plateTex") }

        let avg = library.average(probe)
        scene.lightingEnvironment.contents = probe
        scene.lightingEnvironment.intensity = 1.6
        for m in [turntable.recordTop, turntable.recordBottom] {
            m.reflective.contents = probe
            m.reflective.intensity = 0.35
            m.fresnelExponent = 1.4
        }
        // Diffuse light for the label: the room's average, warm or cool with the hour.
        let level = (avg.x + avg.y + avg.z) / 3
        skyFill.color = NSColor(red: avg.x, green: avg.y, blue: avg.z, alpha: 1)
        skyFill.intensity = CGFloat(500 + 1400 * level)
        sun.intensity = 0
        lamp.intensity = CGFloat(30 * lampLevel)
        shadowLight.shadowColor = NSColor(white: 0, alpha: CGFloat(0.25 + 0.3 * min(1, level * 2)))
    }

    /// How out of focus the window glass is, as a fraction of the frame height: the
    /// lens's blur at infinity (views.json) scaled to the glass's distance.
    private func glassBlur(_ library: PlateLibrary) -> Double {
        guard let card = library.card(framing) else { return 0 }
        let s = Self.shot(framing)
        let cam = SIMD3(Double(s.position.x), Double(s.position.y), Double(s.position.z))
        let w = Self.windowRect
        let glass = simd_distance(cam, SIMD3(Double(w.midX), Double(w.midY), Double(Self.wallZ) - 0.085))
        let focusPoint = SIMD3(TurntableNode.spindleXZ.x, Double(TurntableNode.recordTopY), TurntableNode.spindleXZ.y + 0.05)
        let focus = simd_distance(cam, focusPoint)
        return card.blur * abs(glass - focus) / glass
    }

    /// The plate, with rain on its glass and a breeze in its plant. Everything is in the
    /// plate's own pixels: drops refract the real view behind them, upside down like a lens,
    /// and go soft when the glass is out of focus.
    static let effectsModifier = """
    float platineHash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }

    // Beads sitting on the glass, one per lit cell: each appears, sits, and dries.
    // xy: where to look instead (cell units, towards and past the centre), z: coverage.
    float3 platineBeads(float2 p, float t, float density, float soft) {
        float2 cell = floor(p);
        float2 f = fract(p);
        float3 best = float3(0.0);
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 c = cell + float2(i, j);
                if (platineHash(c + 7.31) > density) continue;
                float2 centre = float2(i, j) + float2(platineHash(c), platineHash(c + 1.7)) * 0.8 + 0.1;
                float life = fract(t * (0.03 + 0.05 * platineHash(c + 3.3)) + platineHash(c + 5.9));
                float grow = smoothstep(0.0, 0.03, life) * (1.0 - smoothstep(0.75, 1.0, life));
                float r = (0.06 + 0.36 * pow(platineHash(c + 9.2), 2.5)) * grow;
                float2 d = centre - f;
                float dist = length(d * float2(1.0, 1.15));
                float m = 1.0 - smoothstep(r * (1.0 - soft), r * (1.0 + 0.6 * soft) + 0.002, dist);
                if (m > best.z) best = float3(d * 1.9, m);
            }
        }
        return best;
    }

    // Drops running down: one per lit column, sliding in fits and starts, a wet trail behind.
    float3 platineRunners(float2 p, float t, float amount, float soft, float aspect) {
        float cols = 9.0 * aspect;
        float col = floor(p.x * cols);
        if (platineHash(float2(col, 2.1)) > amount * 0.7) return float3(0.0);
        float seed = platineHash(float2(col, 8.7));
        float speed = 0.04 + 0.16 * seed * seed;
        float cyc = fract(t * speed + seed * 13.0);
        float y = cyc * 1.3 - 0.15 + 0.02 * sin(cyc * 31.0 + seed * 40.0);
        float cx = (col + 0.3 + 0.4 * platineHash(float2(col, 4.4))) / cols + 0.004 * sin(p.y * 23.0 + seed * 9.0);
        float r = 0.0028 + 0.0022 * seed;
        float2 d = float2(cx - p.x, y - p.y);
        d.y *= p.y < y ? 0.75 : 1.25;                          // pear-shaped: heavy at the bottom
        float dist = length(d);
        float head = 1.0 - smoothstep(r * (1.0 - soft), r * (1.0 + 0.6 * soft) + 0.0015, dist);
        float above = y - p.y;
        float trail = (above > 0.0 && above < 0.3) ? (1.0 - smoothstep(0.0004 * (1.0 + 2.0 * soft), 0.0009 * (1.0 + 2.0 * soft), abs(d.x))) * (1.0 - above / 0.3) * 0.45 : 0.0;
        float m = max(head, trail);
        return float3(d / r * 0.012 * head + float2(d.x * 3.0 * trail, 0.0), m);
    }


    #pragma arguments
    texture2d<float> plateTex;
    texture2d<float> maskTex;
    float rainAmount;
    float4 plant;
    float aspect;
    float glassBlur;

    #pragma body
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = _surface.diffuseTexcoord;
    float t = scn_frame.time;
    float4 masks = maskTex.sample(s, uv);

    // The plant, in a breeze: the higher the leaf, the more it moves.
    float2 look = uv;
    if (plant.z > 0.0 && masks.g > 0.002) {
        float height = clamp((plant.y - uv.y) / max(0.01, plant.y - plant.x), 0.0, 1.0);
        height = smoothstep(0.3, 1.0, height);
        float gust = 0.65 + 0.35 * sin(t * 0.21) * sin(t * 0.13 + 1.0);
        float2 sway = float2(sin(t * 0.9 + uv.y * 7.0) + 0.45 * sin(t * 2.3 + uv.x * 60.0 + uv.y * 41.0),
                             0.35 * sin(t * 1.4 + uv.x * 50.0));
        look -= sway * plant.z * height * gust * masks.g;
    }
    float3 colour = plateTex.sample(s, look).rgb;

    // Rain on the glass.
    if (rainAmount > 0.0 && masks.r > 0.01) {
        float soft = clamp(glassBlur * 25.0, 0.0, 0.85);
        float2 p = float2(uv.x * aspect, uv.y);
        float scale = 85.0;
        float3 a = platineBeads(p * scale, t, 0.25 + 0.55 * rainAmount, soft);
        float3 b = platineBeads(p * scale * 2.3 + 17.0, t * 1.3, 0.2 + 0.5 * rainAmount, soft);
        float3 run = platineRunners(float2(uv.x * aspect, uv.y), t, rainAmount, soft, aspect);
        float2 offset = 0.6 * a.xy / scale * a.z + b.xy / (scale * 2.3) * b.z + run.xy;
        float cover = max(max(a.z, b.z), run.z);
        offset.x /= aspect;
        offset *= (1.0 - 0.45 * soft);
        // Through a drop: the view, flipped and a touch sharper, its rim darker, a glint on top.
        float3 drop = plateTex.sample(s, uv + offset, level(0.0)).rgb;
        float rim = smoothstep(0.5, 1.0, length(offset) * 250.0) * (1.0 - soft);
        drop *= 1.0 - 0.14 * rim;
        drop += 0.07 * (1.0 - soft) * smoothstep(0.0012, 0.0, length(offset + float2(0.0005, 0.0008))) * cover;
        // The glass itself mists over a little in the rain.
        float3 misted = mix(colour, plateTex.sample(s, uv, level(2.5)).rgb * 0.96 + 0.04, 0.5 * rainAmount);
        colour = mix(colour, mix(misted, drop, cover), masks.r);
    }
    _output.color = float4(colour, 1.0);
    """

    /// Multiplies the cover art by the plate's pixel underneath: the plate there is white
    /// paper lit by the room, so the cover gets the exact light, shadows and all.
    static let plateLightModifier = """
    #pragma arguments
    texture2d<float> plateTex;
    #pragma body
    constexpr sampler plateSampler(filter::linear, address::clamp_to_edge);
    float4 clip = scn_frame.projectionTransform * float4(_surface.position, 1.0);
    float2 uv = clip.xy / clip.w * float2(0.5, -0.5) + 0.5;
    float3 light = plateTex.sample(plateSampler, uv).rgb / 0.82;
    _output.color.rgb = _output.color.rgb * light;
    """
}
