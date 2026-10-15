import Foundation

enum PlayerSource: String, Codable {
    case spotify, music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }
}

enum PlayerState: String, Codable { case playing, paused, stopped }

struct TrackInfo: Equatable, Codable {
    var title: String
    var artist: String
    var album: String
    var number: Int
    var disc: Int
    var duration: Double      // seconds
    var id: String
    var artworkURL: String?   // Spotify only
}

/// One reading of a player, with the moment it was taken so the position can
/// be extrapolated between readings.
struct PlayerSnapshot: Equatable {
    var source: PlayerSource
    var state: PlayerState
    var track: TrackInfo?
    var position: Double
    var sampledAt: Date

    func position(at date: Date) -> Double {
        guard let track else { return position }
        let p = state == .playing ? position + date.timeIntervalSince(sampledAt) : position
        return min(max(p, 0), track.duration)
    }
}

/// Fields come back from AppleScript joined by U+001F, records by U+001E.
enum PlayerParsing {
    static let fieldSeparator: Character = "\u{1F}"
    static let recordSeparator: Character = "\u{1E}"

    /// AppleScript may format reals with the user's decimal comma.
    static func number(_ s: Substring) -> Double {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    static func state(_ s: Substring) -> PlayerState {
        // Raw four-char codes show up when the dictionary isn't loaded: kPSP / kPSp.
        if s == "kPSP" { return .playing }
        if s == "kPSp" { return .paused }
        let s = s.lowercased()
        if s.contains("playing") { return .playing }
        if s.contains("paused") { return .paused }
        return .stopped
    }

    /// state, name, artist, album, track#, disc#, duration, position, id[, artwork url]
    static func snapshot(_ output: String, source: PlayerSource, at date: Date = Date()) -> PlayerSnapshot {
        let f = output.split(separator: fieldSeparator, omittingEmptySubsequences: false)
        guard f.count >= 9 else {
            return PlayerSnapshot(source: source, state: .stopped, track: nil, position: 0, sampledAt: date)
        }
        // Spotify reports duration in milliseconds, Music in seconds.
        let rawDuration = number(f[6])
        let duration = source == .spotify ? rawDuration / 1000 : rawDuration
        let track = TrackInfo(title: String(f[1]), artist: String(f[2]), album: String(f[3]),
                              number: Int(number(f[4])), disc: max(1, Int(number(f[5]))),
                              duration: max(1, duration), id: String(f[8]),
                              artworkURL: f.count > 9 && !f[9].isEmpty ? String(f[9]) : nil)
        return PlayerSnapshot(source: source, state: state(f[0]), track: track,
                              position: number(f[7]), sampledAt: date)
    }

    /// Music library rows: track#, disc#, duration, name, artist
    static func libraryTracks(_ output: String, artist: String) -> [LPTrack] {
        struct Row { var track: LPTrack; var artist: String }
        let rows: [Row] = output.split(separator: recordSeparator).compactMap { line in
            let f = line.split(separator: fieldSeparator, omittingEmptySubsequences: false)
            guard f.count >= 5 else { return nil }
            let t = LPTrack(title: String(f[3]), duration: max(1, number(f[2])),
                            number: Int(number(f[0])), disc: max(1, Int(number(f[1]))))
            return Row(track: t, artist: String(f[4]))
        }
        // Same album title from another artist? Keep this artist's if any match.
        let mine = rows.filter { $0.artist.caseInsensitiveCompare(artist) == .orderedSame }
        var seen = Set<String>()
        return (mine.isEmpty ? rows : mine)
            .map(\.track)
            .sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
            .filter { seen.insert("\($0.disc)-\($0.number)-\($0.title)").inserted }
    }

    /// When the full track list is unknown (Spotify without a catalog lookup),
    /// cut a plausible record around the one song we know.
    static func estimatedTracks(around track: TrackInfo) -> [LPTrack] {
        let count = max(track.number + 2, 8)
        return (1...count).map { n in
            n == track.number
                ? LPTrack(title: track.title, duration: track.duration, number: n)
                : LPTrack(title: "", duration: 225, number: n)
        }
    }

    /// Index of the playing track within an album's track list.
    static func index(of track: TrackInfo, in tracks: [LPTrack]) -> Int? {
        if let i = tracks.firstIndex(where: { $0.disc == track.disc && $0.number == track.number
            && ($0.title.isEmpty || $0.title.caseInsensitiveCompare(track.title) == .orderedSame) }) { return i }
        if let i = tracks.firstIndex(where: { $0.title.caseInsensitiveCompare(track.title) == .orderedSame }) { return i }
        if let i = tracks.firstIndex(where: { $0.disc == track.disc && $0.number == track.number }) { return i }
        return nil
    }
}
