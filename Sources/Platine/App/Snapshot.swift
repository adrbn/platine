import AppKit
import SceneKit

/// Offscreen render for checking the room without touching the desktop:
///   Platine --snapshot out.png [--framing close] [--hour 18.5] [--rain 2]
///           [--size 1920x1200] [--track 3] [--position 60] [--paused] [--seconds 8]
///           [--plates dir | --no-plates] [--city tokyo]
@MainActor
enum Snapshot {
    static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let out = value("--snapshot") else { return }
        let framing = Framing(rawValue: value("--framing") ?? "") ?? .wide
        let hour = Double(value("--hour") ?? "") ?? 17.5
        let rain = Int(value("--rain") ?? "") ?? 0
        let dims = (value("--size") ?? "1920x1200").split(separator: "x").compactMap { Double($0) }
        let size = CGSize(width: dims.first ?? 1920, height: dims.last ?? 1200)
        let trackNumber = Int(value("--track") ?? "") ?? 3
        let position = Double(value("--position") ?? "") ?? 60
        let seconds = Double(value("--seconds") ?? "") ?? 8

        // A demo album playing in "Music".
        let demo = DemoRecord.album
        let t = demo.tracks[min(max(trackNumber, 1), demo.tracks.count) - 1]
        let track = TrackInfo(title: t.title, artist: demo.artist, album: demo.title, number: t.number, disc: 1,
                              duration: t.duration, id: "demo-\(t.number)")
        let album = Album(key: Album.key(source: .music, track: track), title: demo.title, artist: demo.artist,
                          tracks: demo.tracks, artwork: demo.artwork, estimated: false)
        let store = PlaybackStore.shared
        store.persists = false
        let state: PlayerState = arguments.contains("--paused") ? .paused : .playing
        store.update(PlayerSnapshot(source: .music, state: state, track: track, position: position, sampledAt: Date()))
        store.setAlbum(album)

        let room = RoomScene()
        let plates = value("--plates").map { PlateLibrary(directory: URL(fileURLWithPath: $0)) } ?? PlateLibrary.bundled
        if !arguments.contains("--no-plates"), let plates {
            room.plateState.aspect = size.width / size.height
            plates.viewBlur = Double(value("--blur") ?? "") ?? 1
            room.usePlates(plates)
            room.setCity(CityViews.find(value("--city") ?? CityViews.defaultID))
            if let photo = value("--import") { room.setCity(try? CityViews.importPhoto(URL(fileURLWithPath: photo))) }
        }
        for name in (value("--hide") ?? "").split(separator: ",") {
            room.scene.rootNode.childNode(withName: String(name), recursively: true)?.isHidden = true
        }
        if arguments.contains("--nofx") {
            room.camera.screenSpaceAmbientOcclusionIntensity = 0
            room.camera.wantsHDR = false
        }
        room.setFraming(framing, animated: false)
        room.updateEnvironment(hour: hour, rain: rain, cloud: 0)
        let director = RecordDirector(room: room)
        director.start()

        // Let the record textures and the first ticks land, then run the arm in.
        let start = Date()
        var simulated = 0.0
        while simulated < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            director.step(dt: 1.0 / 60, now: start.addingTimeInterval(simulated))
            simulated += 1.0 / 60
        }

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = room.scene
        renderer.pointOfView = room.cameraNode
        let image = renderer.snapshot(atTime: 10 + seconds, with: size, antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("snapshot failed\n".data(using: .utf8)!)
            exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: out)) } catch {
            FileHandle.standardError.write("cannot write \(out): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
