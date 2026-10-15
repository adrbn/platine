import AppKit
import Combine

/// The record that belongs on the platter.
struct Album: Equatable {
    let key: String
    let title: String
    let artist: String
    var tracks: [LPTrack]
    var layout: LPLayout
    var artwork: CGImage?
    /// Track list guessed around the songs we've heard (no library entry).
    var estimated: Bool

    init(key: String, title: String, artist: String, tracks: [LPTrack], artwork: CGImage?, estimated: Bool) {
        self.key = key
        self.title = title
        self.artist = artist
        self.tracks = tracks
        self.layout = LPLayout(tracks: tracks)
        self.artwork = artwork
        self.estimated = estimated
    }

    static func key(source: PlayerSource, track: TrackInfo) -> String {
        "\(source.rawValue)|\(track.artist.lowercased())|\(track.album.lowercased())"
    }
}

/// Shared playback state the scenes read from.
@MainActor
final class PlaybackStore: ObservableObject {
    static let shared = PlaybackStore()

    @Published private(set) var snapshot: PlayerSnapshot?
    @Published private(set) var album: Album?
    /// The album played before this one: it sits on top of the pile.
    @Published private(set) var previousAlbum: Album?
    @Published private(set) var resolvingKey: String?
    @Published var automationDenied: Set<PlayerSource> = []

    private(set) var pausedSince: Date?
    /// Off for offscreen snapshots, so they never overwrite your last album.
    var persists = true

    var trackIndex: Int? {
        guard let album, let track = snapshot?.track,
              album.key == Album.key(source: snapshot!.source, track: track) else { return nil }
        return PlayerParsing.index(of: track, in: album.tracks)
    }

    func update(_ new: PlayerSnapshot?) {
        if new?.state == .paused, snapshot?.state != .paused || pausedSince == nil {
            pausedSince = Date()
        } else if new?.state != .paused {
            pausedSince = nil
        }
        snapshot = new

        // Estimated records learn each song's real length as you hear it.
        if var album, album.estimated, let s = new, let track = s.track,
           album.key == Album.key(source: s.source, track: track) {
            var tracks = album.tracks
            if let i = tracks.firstIndex(where: { $0.number == track.number }) {
                if tracks[i].title != track.title || abs(tracks[i].duration - track.duration) > 1 {
                    tracks[i] = LPTrack(title: track.title, duration: track.duration, number: track.number)
                }
            } else if track.number > tracks.count && track.number <= 200 {
                let start = tracks.count + 1
                if start < track.number {
                    tracks += (start..<track.number).map { LPTrack(title: "", duration: 225, number: $0) }
                }
                tracks.append(LPTrack(title: track.title, duration: track.duration, number: track.number))
            }
            if tracks != album.tracks {
                album = Album(key: album.key, title: album.title, artist: album.artist,
                              tracks: tracks, artwork: album.artwork, estimated: true)
                self.album = album
            }
        }
    }

    func beginResolving(_ key: String) { resolvingKey = key }

    func setAlbum(_ new: Album) {
        guard resolvingKey == new.key || resolvingKey == nil else { return }
        resolvingKey = nil
        if let album, album.key != new.key { previousAlbum = album }
        album = new
        if persists { AlbumMemory.save(current: new, previous: previousAlbum) }
    }

    func restoreFromDisk() {
        let (current, previous) = AlbumMemory.load()
        album = current
        previousAlbum = previous
    }

    func setArtwork(_ image: CGImage, for key: String) {
        if album?.key == key { album?.artwork = image }
        else if previousAlbum?.key == key { previousAlbum?.artwork = image }
        else { return }
        if persists, let album { AlbumMemory.save(current: album, previous: previousAlbum) }
    }
}

/// Remembers the last two albums across launches, so the platter and the pile
/// aren't empty before you press play.
enum AlbumMemory {
    private struct Stored: Codable { var key, title, artist: String; var tracks: [LPTrack]; var estimated: Bool }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Platine", isDirectory: true)
    }

    static func save(current: Album, previous: Album?) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        write(current, name: "current")
        if let previous { write(previous, name: "previous") }
    }

    static func load() -> (Album?, Album?) { (read("current"), read("previous")) }

    private static func write(_ album: Album, name: String) {
        let stored = Stored(key: album.key, title: album.title, artist: album.artist,
                            tracks: album.tracks, estimated: album.estimated)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
        }
        let png = dir.appendingPathComponent("\(name).png")
        if let art = album.artwork,
           let data = NSBitmapImageRep(cgImage: art).representation(using: .png, properties: [:]) {
            try? data.write(to: png, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: png)
        }
    }

    private static func read(_ name: String) -> Album? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")),
              let s = try? JSONDecoder().decode(Stored.self, from: data), !s.tracks.isEmpty else { return nil }
        var art: CGImage?
        if let img = NSImage(contentsOf: dir.appendingPathComponent("\(name).png")) {
            art = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        return Album(key: s.key, title: s.title, artist: s.artist, tracks: s.tracks, artwork: art, estimated: s.estimated)
    }
}
