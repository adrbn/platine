import Combine
import os
import SceneKit

/// Turns playback state into turntable moves. The main thread decides what
/// should happen (which record, which side, where the needle goes); the render
/// thread steps the kinematics every frame from a lock-protected cue.
final class RecordDirector: NSObject, SCNSceneRendererDelegate {
    enum Cue {
        case rest
        case hover(rpm: Double)
        case play(band: LPBand, position: Double, sampledAt: Date, playing: Bool, rpm: Double)
    }

    private struct Shared { var cue: Cue = .rest; var parked = true }

    let room: RoomScene
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var motion: TurntableMotion        // render thread only
    private var lastTime: TimeInterval?
    private var rpm = 100.0 / 3

    // Main thread state.
    private var displayed: Album?
    private var displayedSide = 0
    private var busy = false
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var textureGeneration = 0

    init(room: RoomScene) {
        self.room = room
        motion = TurntableMotion(geometry: room.turntable.geometryModel)
        super.init()
    }

    @MainActor func start() {
        let store = PlaybackStore.shared
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.tick() }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    @MainActor func stop() {
        timer?.invalidate()
        cancellables.removeAll()
    }

    // MARK: Main thread

    @MainActor private func tick() {
        let store = PlaybackStore.shared
        let album = store.album ?? DemoRecord.album
        var desiredSide = displayedSide
        var cue = Cue.rest

        if let index = store.trackIndex, let snap = store.snapshot, let (side, band) = album.layout.band(forTrack: index) {
            desiredSide = side
            let rpm = album.layout.rpm
            switch snap.state {
            case .playing:
                cue = .play(band: band, position: snap.position, sampledAt: snap.sampledAt, playing: true, rpm: rpm)
            case .paused:
                // Cue lever up for a while, then the arm goes home and the platter stops.
                if let since = store.pausedSince, Date().timeIntervalSince(since) < 12 { cue = .hover(rpm: rpm) }
            case .stopped:
                break
            }
        } else if store.resolvingKey == nil, store.album == nil {
            desiredSide = 0
        }

        guard !busy else { setCue(.rest); return }

        guard let shown = displayed else {
            // First record: just put it on.
            show(album, side: desiredSide, animation: .none)
            return
        }
        if shown.key != album.key || desiredSide != displayedSide {
            setCue(.rest)
            if shared.withLock({ $0.parked }) {
                show(album, side: desiredSide, animation: shown.key != album.key ? .swap : .flip)
            }
            return
        }
        if shown.layout != album.layout || shown.artwork !== album.artwork {
            // Same record, better knowledge (real song lengths, or the cover arrived).
            show(album, side: desiredSide, animation: .retexture)
        }
        setCue(cue)
    }

    private func setCue(_ cue: Cue) { shared.withLock { $0.cue = cue } }

    private enum Change { case none, swap, flip, retexture }

    @MainActor private func show(_ album: Album, side: Int, animation: Change) {
        let previous = displayed
        displayed = album
        displayedSide = side
        busy = animation == .swap || animation == .flip || animation == .none
        rpm = album.layout.rpm
        textureGeneration += 1
        let generation = textureGeneration
        let sideLayout = album.layout.sides.indices.contains(side) ? album.layout.sides[side] : nil

        var texturesReady: ((CGImage, CGImage)?) = nil
        var waiting: (() -> Void)?
        DispatchQueue.global(qos: .userInitiated).async {
            let t = Textures.recordSide(sideLayout, album: album, rpm: album.layout.rpm)
            DispatchQueue.main.async {
                guard generation == self.textureGeneration else { return }
                texturesReady = (t.diffuse, t.specular)
                waiting?()
                waiting = nil
            }
        }
        func whenReady(_ block: @escaping () -> Void) {
            if texturesReady != nil { block() } else { waiting = block }
        }
        func applyTextures() {
            guard let (d, s) = texturesReady else { return }
            for m in [room.turntable.recordTop, room.turntable.recordBottom] {
                m.diffuse.contents = d
                m.specular.contents = s
            }
        }
        let record = room.turntable.recordGroup
        let finish: () -> Void = { [weak self] in self?.busy = false; self?.tick() }

        switch animation {
        case .none:
            whenReady {
                applyTextures()
                self.room.setCover(album.artwork, title: album.title, artist: album.artist, animated: false)
                if let p = PlaybackStore.shared.previousAlbum {
                    self.room.setPileCover(p.artwork, title: p.title, artist: p.artist)
                } else {
                    self.room.setPileCover(nil, title: "Chuva de Verão", artist: "")
                }
                finish()
            }
        case .retexture:
            whenReady {
                applyTextures()
                if previous?.artwork !== album.artwork {
                    self.room.setCover(album.artwork, title: album.title, artist: album.artist, animated: true)
                }
            }
        case .swap:
            // Lift the old record off, put the new one on; its sleeve takes the stand,
            // the old sleeve goes on top of the pile.
            if let previous { room.setPileCover(previous.artwork, title: previous.title, artist: previous.artist) }
            room.setCover(album.artwork, title: album.title, artist: album.artist, animated: true)
            let up = SCNAction.group([.moveBy(x: 0, y: 0.16, z: 0, duration: 0.7), .fadeOut(duration: 0.7)])
            up.timingMode = .easeIn
            record.runAction(up) {
                DispatchQueue.main.async {
                    whenReady {
                        applyTextures()
                        let down = SCNAction.group([.moveBy(x: 0, y: -0.16, z: 0, duration: 0.8), .fadeIn(duration: 0.6)])
                        down.timingMode = .easeOut
                        record.runAction(down) { DispatchQueue.main.async(execute: finish) }
                    }
                }
            }
        case .flip:
            let lift = SCNAction.moveBy(x: 0, y: 0.06, z: 0, duration: 0.4)
            lift.timingMode = .easeOut
            let half = SCNAction.rotateBy(x: .pi / 2, y: 0, z: 0, duration: 0.35)
            record.runAction(.sequence([lift, half])) {
                DispatchQueue.main.async {
                    whenReady {
                        applyTextures()
                        let rest = SCNAction.rotateBy(x: .pi / 2, y: 0, z: 0, duration: 0.35)
                        let drop = SCNAction.moveBy(x: 0, y: -0.06, z: 0, duration: 0.45)
                        drop.timingMode = .easeIn
                        record.runAction(.sequence([rest, .run { $0.eulerAngles.x = 0 }, drop])) {
                            DispatchQueue.main.async(execute: finish)
                        }
                    }
                }
            }
        }
    }

    // MARK: Render thread

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime.map { time - $0 } ?? 0
        lastTime = time
        step(dt: dt, now: Date())
    }

    /// One kinematic step. Also used directly by offscreen snapshots.
    func step(dt: Double, now: Date) {
        let cue = shared.withLock { $0.cue }
        let mode: TurntableMode
        var rpmNow = rpm
        switch cue {
        case .rest:
            mode = .rest
        case .hover(let r):
            rpmNow = r
            mode = .cue(rpm: r)
        case .play(let band, let position, let at, let playing, let r):
            rpmNow = r
            let p = playing ? position + now.timeIntervalSince(at) : position
            let t = min(max(p / band.duration, 0), 1)
            mode = .play(radius: band.outerRadius - (band.outerRadius - band.innerRadius) * t, rpm: r)
        }
        motion.step(dt: dt, mode: mode)
        room.turntable.apply(motion, rpm: rpmNow)
        room.turntable.updateVinylCenter(camera: room.cameraNode)
        let parked = motion.isParked
        shared.withLock { $0.parked = parked }
    }
}

/// The record on the platter before you've played anything.
enum DemoRecord {
    static let album: Album = {
        let titles = ["Garoa na Paulista", "Rede no alpendre", "Tarde de cajá", "Ladeira do sol", "Laranja-da-terra",
                      "Minhocão", "Bonde das seis", "Luz de mercúrio", "Volta pra casa"]
        let durations: [Double] = [221, 200, 242, 213, 228, 251, 196, 238, 264]
        let tracks = zip(titles, durations).enumerated().map { LPTrack(title: $0.element.0, duration: $0.element.1, number: $0.offset + 1) }
        return Album(key: "demo", title: "Garoa", artist: "Platine", tracks: tracks,
                     artwork: Textures.fallbackCover(title: "Garoa", artist: "Platine"), estimated: false)
    }()
}
