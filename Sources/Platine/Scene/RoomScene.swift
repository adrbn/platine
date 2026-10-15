import SceneKit

/// The room: a desk under a window over the city, the turntable, a coffee,
/// a pile of records, the sleeve on its stand, a lamp for the evening.
final class RoomScene {
    let scene = SCNScene()
    let turntable = TurntableNode()
    let cameraNode = SCNNode()
    let camera = SCNCamera()

    let sun = SCNLight()
    private let sunNode = SCNNode()
    let skyFill = SCNLight()
    let skyFillNode = SCNNode()
    let lamp = SCNLight()
    private let bulb = SCNMaterial()
    private let skyMaterial = SCNMaterial()
    private let cityDay = SCNMaterial()
    private let cityNight = SCNMaterial()
    let glassRain = SCNParticleSystem()
    let glassBeads = SCNParticleSystem()
    let outsideRain = SCNParticleSystem()
    private(set) var sleeveFaces: [SCNNode] = []
    private var cityNightNode = SCNNode()
    let bounce = SCNLight()
    let shadowLight = SCNLight()
    private var activeSleeve = 0
    let pileTop = SCNMaterial()
    /// Nodes the Cycles plates don't contain: drawn live over them.
    private(set) var liveNodes: [SCNNode] = []
    /// Sky and city planes, replaced by the plates.
    private(set) var outsideNodes: [SCNNode] = []
    var plateState = PlateState()
    private(set) var framing: Framing = .wide

    static let windowRect = CGRect(x: -0.78, y: 0.14, width: 1.16, height: 1.12)
    static let wallZ: CGFloat = -0.55

    init() {
        buildDesk()
        buildWall()
        buildOutside()
        buildProps()
        buildLights()
        buildRain()
        scene.rootNode.addChildNode(turntable)
        buildCamera()
        setFraming(.wide, animated: false)
        updateEnvironment(hour: 12, rain: 0, cloud: 0)
    }

    // MARK: Building

    private func add(_ g: SCNGeometry, _ m: SCNMaterial, _ p: SCNVector3, to parent: SCNNode? = nil) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = p
        (parent ?? scene.rootNode).addChildNode(n)
        return n
    }

    private func buildDesk() {
        let wood = TurntableNode.pbr(.white, rough: 0.55, texture: Textures.wood())
        wood.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 1, 1)
        _ = add(SCNBox(width: 2.4, height: 0.04, length: 1.0, chamferRadius: 0.004), wood, SCNVector3(-0.1, -0.02, -0.05))
    }

    private func buildWall() {
        let plaster = TurntableNode.pbr(.white, rough: 0.95, texture: Textures.plaster())
        let w = Self.windowRect
        let z = Self.wallZ - 0.07
        let depth: CGFloat = 0.14
        func block(_ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            _ = add(SCNBox(width: x1 - x0, height: y1 - y0, length: depth, chamferRadius: 0), plaster,
                    SCNVector3((x0 + x1) / 2, (y0 + y1) / 2, z))
        }
        block(-3, w.minX, -1, 2.6)
        block(w.maxX, 3, -1, 2.6)
        block(w.minX, w.maxX, -1, w.minY)
        block(w.minX, w.maxX, w.maxY, 2.6)

        // Steel frame with a mullion and a transom.
        let steel = TurntableNode.pbr(NSColor(white: 0.13, alpha: 1), metal: 0.6, rough: 0.45)
        let fz = Self.wallZ - 0.09
        let t: CGFloat = 0.028
        func bar(_ x: CGFloat, _ y: CGFloat, _ bw: CGFloat, _ bh: CGFloat) {
            _ = add(SCNBox(width: bw, height: bh, length: 0.035, chamferRadius: 0.002), steel, SCNVector3(x, y, fz))
        }
        bar(w.midX, w.minY + t / 2, w.width, t)
        bar(w.midX, w.maxY - t / 2, w.width, t)
        bar(w.minX + t / 2, w.midY, t, w.height)
        bar(w.maxX - t / 2, w.midY, t, w.height)
        bar(w.midX, w.midY, t * 0.7, w.height)
        bar(w.midX, w.minY + w.height * 0.7, w.width, t * 0.7)
        // Sill.
        _ = add(SCNBox(width: w.width + 0.08, height: 0.025, length: 0.1, chamferRadius: 0.004),
                TurntableNode.pbr(NSColor(white: 0.8, alpha: 1), rough: 0.6), SCNVector3(w.midX, w.minY - 0.012, Self.wallZ - 0.02))

        // Glass: barely there, but it catches a reflection.
        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = NSColor(white: 1, alpha: 1)
        glass.roughness.contents = 0.02
        glass.metalness.contents = 0.0
        glass.writesToDepthBuffer = false
        let pane = add(SCNPlane(width: w.width, height: w.height), glass, SCNVector3(w.midX, w.midY, fz - 0.005))
        pane.castsShadow = false
        pane.opacity = 0.07
        pane.renderingOrder = 5
        pane.name = "glass"
    }

    private func buildOutside() {
        for m in [skyMaterial, cityDay, cityNight] {
            m.lightingModel = .constant
            m.writesToDepthBuffer = true
        }
        let sky = add(SCNPlane(width: 40, height: 22), skyMaterial, SCNVector3(-0.2, 3, -12))
        sky.castsShadow = false
        outsideNodes.append(sky)

        cityDay.diffuse.contents = Textures.city(night: false)
        cityNight.diffuse.contents = Textures.city(night: true)
        let day = add(SCNPlane(width: 24, height: 5.3), cityDay, SCNVector3(-0.3, 0.55, -9))
        cityNightNode = add(SCNPlane(width: 24, height: 5.3), cityNight, SCNVector3(-0.3, 0.55, -8.99))
        cityNightNode.name = "cityNight"
        for n in [day, cityNightNode] { n.castsShadow = false }
        outsideNodes += [day, cityNightNode]
    }

    private func buildProps() {
        // Coffee, steaming either way.
        let ceramic = TurntableNode.pbr(NSColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1), rough: 0.25)
        let mugX: CGFloat = 0.40, mugZ: CGFloat = 0.17
        _ = add(SCNTube(innerRadius: 0.037, outerRadius: 0.042, height: 0.095), ceramic, SCNVector3(mugX, 0.0475, mugZ))
        _ = add(SCNCylinder(radius: 0.042, height: 0.006), ceramic, SCNVector3(mugX, 0.003, mugZ))
        let coffee = TurntableNode.pbr(NSColor(red: 0.12, green: 0.06, blue: 0.03, alpha: 1), rough: 0.08)
        _ = add(SCNCylinder(radius: 0.037, height: 0.002), coffee, SCNVector3(mugX, 0.082, mugZ))
        let handle = add(SCNTorus(ringRadius: 0.026, pipeRadius: 0.0065), ceramic, SCNVector3(mugX + 0.048, 0.05, mugZ))
        handle.eulerAngles.x = .pi / 2
        _ = add(SCNCylinder(radius: 0.075, height: 0.006), ceramic, SCNVector3(mugX, 0.0, mugZ))

        // Steam: thin, slow wisps that rise, curl in the air of the room and thin out.
        let steam = SCNParticleSystem()
        steam.particleImage = Textures.softDot(size: 128, alpha: 0.5, hardness: 0.0)
        steam.birthRate = 22
        steam.warmupDuration = 6
        steam.particleLifeSpan = 4.5
        steam.particleLifeSpanVariation = 1.5
        steam.emitterShape = SCNCylinder(radius: 0.02, height: 0.001)
        steam.birthLocation = .volume
        steam.particleVelocity = 0.022
        steam.particleVelocityVariation = 0.01
        steam.emittingDirection = SCNVector3(0, 1, 0)
        steam.spreadingAngle = 8
        steam.acceleration = SCNVector3(0.002, 0.004, 0)
        steam.particleSize = 0.006
        steam.particleSizeVariation = 0.003
        steam.particleColor = NSColor(white: 1, alpha: 0.07)
        steam.particleAngularVelocity = 20
        steam.particleAngularVelocityVariation = 30
        steam.stretchFactor = 0.6
        steam.blendMode = .screen
        steam.isLightingEnabled = false
        steam.sortingMode = .none
        steam.isAffectedByPhysicsFields = true
        let fade = CAKeyframeAnimation()
        fade.values = [0, 1, 0.7, 0.25, 0]
        fade.keyTimes = [0, 0.1, 0.4, 0.75, 1]
        let grow = CAKeyframeAnimation()
        grow.values = [0.6, 2.2, 5.5]
        steam.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade),
                                     .size: SCNParticlePropertyController(animation: grow)]
        // The air above the cup is never still: a slow turbulence twists the wisps.
        let air = SCNNode()
        air.position = SCNVector3(mugX, 0.2, mugZ)
        let curl = SCNPhysicsField.turbulenceField(smoothness: 0.9, animationSpeed: 0.35)
        curl.strength = 0.05
        curl.halfExtent = SCNVector3(0.15, 0.2, 0.15)
        air.physicsField = curl
        scene.rootNode.addChildNode(air)
        let emitter = SCNNode()
        emitter.position = SCNVector3(mugX, 0.088, mugZ)
        emitter.addParticleSystem(steam)
        scene.rootNode.addChildNode(emitter)
        liveNodes.append(emitter)

        // The pile: the record on top is the last album you played.
        var rnd = SeededRandom(seed: 77)
        let pile = SCNNode()
        pile.position = SCNVector3(-0.66, 0, -0.16)
        pile.eulerAngles.y = 0.12
        scene.rootNode.addChildNode(pile)
        let tones: [NSColor] = [.init(red: 0.78, green: 0.7, blue: 0.56, alpha: 1), .init(red: 0.2, green: 0.25, blue: 0.3, alpha: 1),
                                .init(red: 0.65, green: 0.25, blue: 0.18, alpha: 1), .init(red: 0.9, green: 0.88, blue: 0.82, alpha: 1),
                                .init(red: 0.15, green: 0.15, blue: 0.14, alpha: 1), .init(red: 0.45, green: 0.55, blue: 0.4, alpha: 1)]
        for i in 0..<9 {
            let card = TurntableNode.pbr(tones[i % tones.count], rough: 0.8)
            let box = SCNBox(width: 0.315, height: 0.0055, length: 0.315, chamferRadius: 0.0008)
            let top = i == 8 ? pileTop : card
            if i == 8 { pileTop.lightingModel = .physicallyBased; pileTop.roughness.contents = 0.6 }
            box.materials = [card, card, card, card, top, card]
            let n = SCNNode(geometry: box)
            n.position = SCNVector3(Double(rnd.range(-0.008, 0.008)), 0.003 + 0.0056 * Double(i), Double(rnd.range(-0.008, 0.008)))
            n.eulerAngles.y = rnd.range(-0.05, 0.05)
            pile.addChildNode(n)
        }

        // The sleeve on its stand, leaning on the wall. Two faces cross-fade on album change.
        let stand = SCNNode()
        stand.position = SCNVector3(0.62, 0, -0.43)
        stand.eulerAngles.y = -0.35
        scene.rootNode.addChildNode(stand)
        _ = add(SCNBox(width: 0.2, height: 0.012, length: 0.06, chamferRadius: 0.003),
                TurntableNode.pbr(NSColor(red: 0.3, green: 0.18, blue: 0.1, alpha: 1), rough: 0.5), SCNVector3(0, 0.006, 0), to: stand)
        let lean = SCNNode()
        lean.position = SCNVector3(0, 0.012, -0.01)
        lean.eulerAngles.x = -0.16
        stand.addChildNode(lean)
        let backing = add(SCNBox(width: 0.315, height: 0.315, length: 0.003, chamferRadius: 0.0005),
                          TurntableNode.pbr(NSColor(white: 0.85, alpha: 1), rough: 0.85), SCNVector3(0, 0.1575, -0.002), to: lean)
        backing.castsShadow = true
        for i in 0..<2 {
            let m = TurntableNode.pbr(.white, rough: 0.55)
            let face = add(SCNPlane(width: 0.313, height: 0.313), m, SCNVector3(0, 0.1575, 0.0002 + 0.0002 * CGFloat(i)), to: lean)
            face.castsShadow = false
            face.opacity = i == 0 ? 1 : 0
            sleeveFaces.append(face)
            liveNodes.append(face)
        }

        // Desk lamp.
        let brass = TurntableNode.pbr(NSColor(red: 0.75, green: 0.6, blue: 0.35, alpha: 1), metal: 1, rough: 0.35)
        let lampBase = SCNNode()
        lampBase.position = SCNVector3(0.86, 0, -0.3)
        scene.rootNode.addChildNode(lampBase)
        _ = add(SCNCylinder(radius: 0.07, height: 0.015), brass, SCNVector3(0, 0.0075, 0), to: lampBase)
        lampBase.addChildNode(TurntableNode.segment(from: SCNVector3(0, 0.01, 0), to: SCNVector3(-0.05, 0.42, 0.05), radius: 0.006, material: brass))
        lampBase.addChildNode(TurntableNode.segment(from: SCNVector3(-0.05, 0.42, 0.05), to: SCNVector3(-0.21, 0.455, 0.125), radius: 0.006, material: brass))
        let shade = SCNCone(topRadius: 0.025, bottomRadius: 0.075, height: 0.11)
        let shadeMat = TurntableNode.pbr(NSColor(red: 0.16, green: 0.25, blue: 0.2, alpha: 1), metal: 0.3, rough: 0.4)
        shadeMat.isDoubleSided = true
        let shadeNode = add(shade, shadeMat, SCNVector3(-0.24, 0.42, 0.13), to: lampBase)
        shadeNode.eulerAngles.z = -0.45
        bulb.lightingModel = .constant
        bulb.diffuse.contents = NSColor.black
        _ = add(SCNSphere(radius: 0.022), bulb, SCNVector3(0, -0.045, 0), to: shadeNode)
        lamp.type = .spot
        lamp.color = NSColor(red: 1, green: 0.72, blue: 0.45, alpha: 1)
        lamp.spotInnerAngle = 25
        lamp.spotOuterAngle = 120
        lamp.attenuationStartDistance = 0.2
        lamp.attenuationEndDistance = 2.2
        lamp.castsShadow = false
        let lampNode = SCNNode()
        lampNode.light = lamp
        lampNode.position = SCNVector3(0, -0.05, 0)
        lampNode.eulerAngles.x = -.pi / 2
        shadeNode.addChildNode(lampNode)
    }

    private func buildLights() {
        sun.type = .directional
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowSampleCount = 8
        sun.shadowRadius = 4
        sun.shadowMode = .forward
        sun.shadowColor = NSColor(white: 0, alpha: 0.85)
        sun.automaticallyAdjustsShadowProjection = true
        sun.maximumShadowDistance = 3
        sunNode.light = sun
        scene.rootNode.addChildNode(sunNode)

        skyFill.type = .directional
        skyFill.castsShadow = false
        skyFillNode.light = skyFill
        skyFillNode.look(at: SCNVector3(0.1, -0.35, 1))
        scene.rootNode.addChildNode(skyFillNode)

        // Light bounced off the room behind the camera: warm, soft, no shadows.
        bounce.type = .directional
        bounce.castsShadow = false
        let bn = SCNNode()
        bn.light = bounce
        bn.look(at: SCNVector3(-0.25, -0.6, -1))
        scene.rootNode.addChildNode(bn)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 40
        ambient.color = NSColor(red: 1, green: 0.9, blue: 0.8, alpha: 1)
        let an = SCNNode()
        an.light = ambient
        an.name = "ambient"
        scene.rootNode.addChildNode(an)
    }

    private func buildRain() {
        let w = Self.windowRect
        let paneZ = Self.wallZ - 0.085

        glassBeads.particleImage = Textures.raindrop()
        glassBeads.emitterShape = SCNPlane(width: w.width - 0.06, height: w.height - 0.06)
        glassBeads.birthLocation = .surface
        glassBeads.particleLifeSpan = 9
        glassBeads.particleLifeSpanVariation = 4
        glassBeads.particleSize = 0.0035
        glassBeads.particleSizeVariation = 0.0025
        glassBeads.particleVelocity = 0.002
        glassBeads.emittingDirection = SCNVector3(0, -1, 0)
        glassBeads.particleColor = NSColor(white: 1, alpha: 0.75)
        glassBeads.isLightingEnabled = false
        glassBeads.blendMode = .alpha
        glassBeads.birthRate = 0
        glassBeads.warmupDuration = 8

        glassRain.particleImage = Textures.raindrop()
        glassRain.emitterShape = SCNPlane(width: w.width - 0.06, height: w.height - 0.06)
        glassRain.birthLocation = .surface
        glassRain.particleLifeSpan = 2.5
        glassRain.particleLifeSpanVariation = 1.5
        glassRain.particleSize = 0.005
        glassRain.particleSizeVariation = 0.002
        glassRain.particleVelocity = 0.06
        glassRain.particleVelocityVariation = 0.05
        glassRain.emittingDirection = SCNVector3(0, -1, 0)
        glassRain.spreadingAngle = 6
        glassRain.stretchFactor = 0.25
        glassRain.particleColor = NSColor(white: 1, alpha: 0.7)
        glassRain.isLightingEnabled = false
        glassRain.blendMode = .alpha
        glassRain.birthRate = 0
        glassRain.warmupDuration = 3

        let glassNode = SCNNode()
        glassNode.position = SCNVector3(w.midX, w.midY, paneZ + 0.004)
        glassNode.addParticleSystem(glassBeads)
        glassNode.addParticleSystem(glassRain)
        scene.rootNode.addChildNode(glassNode)
        liveNodes.append(glassNode)

        outsideRain.particleImage = Textures.streak()
        outsideRain.emitterShape = SCNBox(width: 6, height: 0.1, length: 3, chamferRadius: 0)
        outsideRain.birthLocation = .volume
        outsideRain.particleLifeSpan = 1.4
        outsideRain.particleVelocity = 4.5
        outsideRain.particleVelocityVariation = 0.8
        outsideRain.emittingDirection = SCNVector3(0.05, -1, 0)
        outsideRain.particleSize = 0.012
        outsideRain.stretchFactor = 0.06
        outsideRain.particleColor = NSColor(white: 0.9, alpha: 0.22)
        outsideRain.isLightingEnabled = false
        outsideRain.blendMode = .additive
        outsideRain.birthRate = 0
        outsideRain.warmupDuration = 1.5
        let outside = SCNNode()
        outside.position = SCNVector3(-0.2, 3.2, -2.8)
        outside.addParticleSystem(outsideRain)
        scene.rootNode.addChildNode(outside)
        liveNodes.append(outside)
    }

    private func buildCamera() {
        camera.zNear = 0.05
        camera.zFar = 20
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.35
        camera.bloomThreshold = 0.9
        camera.bloomBlurRadius = 10
        camera.vignettingIntensity = 0.55
        camera.vignettingPower = 0.6
        camera.screenSpaceAmbientOcclusionIntensity = 0.8
        camera.screenSpaceAmbientOcclusionRadius = 0.05
        camera.screenSpaceAmbientOcclusionBias = 0.01
        camera.grainIntensity = 0.08
        camera.grainScale = 1
        camera.saturation = 1.05
        camera.contrast = 0.08
        camera.focalBlurSampleCount = 12
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: Framings

    struct Shot { var position: SCNVector3; var target: SCNVector3; var fov: CGFloat; var fStop: CGFloat }

    static func shot(_ f: Framing) -> Shot {
        switch f {
        case .wide:   return Shot(position: SCNVector3(0.02, 0.62, 1.55), target: SCNVector3(-0.12, 0.36, -0.3), fov: 42, fStop: 0)
        case .medium: return Shot(position: SCNVector3(0.06, 0.42, 0.74), target: SCNVector3(-0.02, 0.1, -0.06), fov: 40, fStop: 5.6)
        case .close:  return Shot(position: SCNVector3(0.27, 0.215, 0.29), target: SCNVector3(0.02, 0.11, 0.0), fov: 36, fStop: 2.8)
        case .above:  return Shot(position: SCNVector3(0.0, 0.98, 0.16), target: SCNVector3(0.0, 0.09, -0.01), fov: 40, fStop: 0)
        }
    }

    func setFraming(_ f: Framing, animated: Bool) {
        framing = f
        if usesPlates {
            applyPlateCamera()
            plateState.lastKey = ""
            return
        }
        let s = Self.shot(f)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 1.4 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.position = s.position
        cameraNode.look(at: s.target)
        camera.fieldOfView = s.fov
        camera.wantsDepthOfField = s.fStop > 0
        if s.fStop > 0 {
            camera.fStop = s.fStop
            let stylus = turntable.convertPosition(SCNVector3(-0.0, TurntableNode.recordTopY, 0.05), to: nil)
            let d = SCNVector3(stylus.x - s.position.x, stylus.y - s.position.y, stylus.z - s.position.z)
            camera.focusDistance = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        }
        SCNTransaction.commit()
    }

    // MARK: Environment

    /// Light for this hour, greyed by rain or cloud. Cheap: call every few seconds.
    func updateEnvironment(hour: Double, rain: Int, cloud: Double) {
        let overcast = max(Double(rain) / 2.5, max(0, cloud - 0.6) * 1.2)
        let d = DayCycle.light(atHour: hour).overcast(overcast)
        plateState.rain = [0, 0.35, 0.65, 1][min(3, max(0, rain))]
        plateState.effects.geometry?.firstMaterial?.setValue(Float(plateState.rain), forKey: "rainAmount")
        if usesPlates {
            updatePlates(hour: hour, overcast: overcast, lamp: d.lamp)
            return
        }
        glassBeads.birthRate = [0, 6, 14, 26][min(3, max(0, rain))]
        glassRain.birthRate = [0, 1.5, 6, 16][min(3, max(0, rain))]
        outsideRain.birthRate = [0, 120, 420, 900][min(3, max(0, rain))]

        skyMaterial.diffuse.contents = Textures.sky(top: d.skyTop, horizon: d.skyHorizon)
        let tint = d.skyHorizon * 0.55 + SIMD3(repeating: 0.45)
        let dayLevel = 1 - d.cityLights
        cityDay.multiply.contents = NSColor(red: tint.x * (0.25 + 0.75 * dayLevel), green: tint.y * (0.25 + 0.75 * dayLevel),
                                            blue: tint.z * (0.25 + 0.75 * dayLevel), alpha: 1)
        cityNightNode.opacity = d.cityLights
        cityNight.multiply.contents = NSColor(white: 1.6, alpha: 1)

        let sweep = DayCycle.sunSweep(atHour: hour)
        let dir = SIMD3(sweep * 0.7, -sin(max(0.08, d.sunElevation)), cos(max(0.08, d.sunElevation)))
        sunNode.position = SCNVector3(-dir.x * 3, -dir.y * 3, -dir.z * 3 - 0.5)
        sunNode.look(at: SCNVector3(sunNode.position.x + dir.x, sunNode.position.y + dir.y, sunNode.position.z + dir.z))
        sun.color = NSColor(red: d.sunColor.x, green: d.sunColor.y, blue: d.sunColor.z, alpha: 1)
        sun.intensity = d.sunIntensity

        skyFill.color = NSColor(red: d.skyHorizon.x * 0.5 + d.skyTop.x * 0.5, green: d.skyHorizon.y * 0.5 + d.skyTop.y * 0.5,
                                blue: d.skyHorizon.z * 0.5 + d.skyTop.z * 0.5, alpha: 1)
        skyFill.intensity = 650 * d.ambient

        scene.lightingEnvironment.contents = skyMaterial.diffuse.contents
        scene.lightingEnvironment.intensity = 0.25 + 0.9 * d.ambient

        let warm = d.sunColor * 0.5 + SIMD3(1, 0.86, 0.72) * 0.5
        bounce.color = NSColor(red: warm.x, green: warm.y, blue: warm.z, alpha: 1)
        bounce.intensity = 60 + 0.22 * d.sunIntensity + 90 * d.lamp

        lamp.intensity = 38 * d.lamp
        bulb.diffuse.contents = NSColor(red: 1 + 3 * d.lamp, green: 0.7 + 2 * d.lamp, blue: 0.4 + 1 * d.lamp, alpha: 1)
            .blended(withFraction: 1 - d.lamp, of: NSColor(white: 0.85, alpha: 1))
        // The eye adapts: a darker room gets a longer exposure, not a black screen.
        camera.exposureOffset = CGFloat(0.35 + 1.1 * (1 - min(1, d.sunIntensity / 1500)) - 0.3 * d.lamp)
    }

    // MARK: Sleeves

    func setCover(_ image: CGImage?, title: String, artist: String, animated: Bool) {
        let art = image ?? Textures.fallbackCover(title: title, artist: artist)
        let next = 1 - activeSleeve
        sleeveFaces[next].geometry?.firstMaterial?.diffuse.contents = art
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 1.2 : 0
        sleeveFaces[next].opacity = 1
        sleeveFaces[activeSleeve].opacity = 0
        SCNTransaction.commit()
        activeSleeve = next
    }

    func setPileCover(_ image: CGImage?, title: String, artist: String) {
        pileTop.diffuse.contents = image ?? Textures.fallbackCover(title: title, artist: artist)
    }
}
