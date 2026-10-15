import AppKit
import os

private let log = Logger(subsystem: "com.adrbn.platine", category: "players")

/// Follows Spotify and Music: listens to their distributed notifications, reads
/// state over AppleScript, and resolves the album's track list and cover.
/// Never launches a player: every script is gated on the app already running.
@MainActor
final class PlayerBridge {
    private let store: PlaybackStore
    private let settings: Settings
    private let queue = DispatchQueue(label: "com.adrbn.platine.applescript", qos: .utility)
    private var latest: [PlayerSource: PlayerSnapshot] = [:]
    private var lastChange: [PlayerSource: Date] = [:]
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var tick = 0
    private var artTried: Set<String> = []

    init() {
        let store = PlaybackStore.shared, settings = Settings.shared
        self.store = store
        self.settings = settings
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.spotify) }
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(.music) }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if app?.bundleIdentifier == PlayerSource.spotify.bundleID { self?.refresh(.spotify) }
                    if app?.bundleIdentifier == PlayerSource.music.bundleID { self?.refresh(.music) }
                }
            })
        }
        // Resync the position every 3 s while playing, every 15 s otherwise.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        refresh(.spotify)
        refresh(.music)
        // Records remembered without a cover (the pile's, mostly): ask Apple's catalog for it.
        for album in [store.album, store.previousAlbum].compactMap({ $0 }) where album.artwork == nil {
            artTried.insert(album.key)
            let key = album.key, artist = album.artist, title = album.title
            queue.async {
                guard let url = CatalogLookup.album(artist: artist, title: title)?.artwork else { return }
                DispatchQueue.main.async { Self.download(url, key: key) }
            }
        }
    }

    private func poll() {
        tick += 1
        for source in [PlayerSource.spotify, .music] {
            if latest[source]?.state == .playing || tick % 5 == 0 { refresh(source) }
        }
    }

    private func isRunning(_ source: PlayerSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    func refresh(_ source: PlayerSource) {
        guard isRunning(source) else {
            if latest.removeValue(forKey: source) != nil { publish() }
            return
        }
        let script = source == .spotify ? Scripts.spotifyState : Scripts.musicState
        queue.async { [weak self] in
            let result = AppleScriptRunner.run(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(result, from: source) }
            }
        }
    }

    private func receive(_ result: AppleScriptRunner.Result, from source: PlayerSource) {
        switch result {
        case .denied:
            store.automationDenied.insert(source)
            latest[source] = nil
        case .failed:
            latest[source] = nil
        case .output(let text):
            store.automationDenied.remove(source)
            let snap = PlayerParsing.snapshot(text, source: source)
            let old = latest[source]
            if old?.state != snap.state || old?.track?.id != snap.track?.id { lastChange[source] = Date() }
            latest[source] = snap.track == nil ? nil : snap
        }
        publish()
    }

    /// Pick the player to show: whichever is playing (most recent change wins),
    /// else whichever was paused most recently.
    private func publish() {
        let candidates = latest.values.sorted {
            if ($0.state == .playing) != ($1.state == .playing) { return $0.state == .playing }
            return (lastChange[$0.source] ?? .distantPast) > (lastChange[$1.source] ?? .distantPast)
        }
        let active = candidates.first
        store.update(active)
        if let active, let track = active.track {
            let key = Album.key(source: active.source, track: track)
            if store.album?.key != key && store.resolvingKey != key { resolveAlbum(for: track, source: active.source) }
            // A record remembered without its cover (quit before the download landed): fetch it once more.
            else if store.album?.key == key, store.album?.artwork == nil, artTried.insert(key).inserted {
                fetchArtwork(track, source: active.source, key: key)
            }
        }
    }

    // MARK: Album resolution

    private func resolveAlbum(for track: TrackInfo, source: PlayerSource) {
        let key = Album.key(source: source, track: track)
        store.beginResolving(key)
        let lookup = settings.catalogLookup
        log.info("resolving album \(track.album, privacy: .private)")

        queue.async { [weak self] in
            var tracks: [LPTrack] = []
            var estimated = false
            var catalogArt: URL?

            if track.album.isEmpty {
                tracks = [LPTrack(title: track.title, duration: track.duration, number: 1)]
            } else {
                if source == .music, case .output(let rows) = AppleScriptRunner.run(Scripts.musicAlbum(track.album)) {
                    tracks = PlayerParsing.libraryTracks(rows, artist: track.artist)
                }
                if tracks.isEmpty, lookup, let found = CatalogLookup.album(artist: track.artist, title: track.album) {
                    tracks = found.tracks
                    catalogArt = found.artwork
                }
                if tracks.isEmpty || PlayerParsing.index(of: track, in: tracks) == nil {
                    tracks = PlayerParsing.estimatedTracks(around: track)
                    estimated = true
                }
            }

            var art: CGImage?
            if source == .music, case .data(let data) = AppleScriptRunner.runData(Scripts.musicArtwork) {
                art = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            let artURL = track.artworkURL.flatMap(URL.init(string:)) ?? catalogArt
            let album = Album(key: key, title: track.album.isEmpty ? track.title : track.album,
                              artist: track.artist, tracks: tracks, artwork: art, estimated: estimated)

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.store.setAlbum(album)
                    if art == nil, let artURL { Self.download(artURL, key: key) }
                }
            }
        }
    }

    private func fetchArtwork(_ track: TrackInfo, source: PlayerSource, key: String) {
        if let url = track.artworkURL.flatMap(URL.init(string:)) { Self.download(url, key: key); return }
        guard source == .music else { return }
        queue.async {
            guard case .data(let data) = AppleScriptRunner.runData(Scripts.musicArtwork),
                  let art = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { PlaybackStore.shared.setArtwork(art, for: key) } }
        }
    }

    /// Covers come from the player's own CDN (Spotify) or Apple's catalog.
    private static func download(_ url: URL, key: String) {
        guard url.scheme == "https" else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { PlaybackStore.shared.setArtwork(image, for: key) }
            }
        }.resume()
    }
}

// MARK: - AppleScript

enum AppleScriptRunner {
    enum Result { case output(String), denied, failed }
    enum DataResult { case data(Data), failed }

    /// Must be called from the bridge's serial queue only.
    static func run(_ source: String) -> Result {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743: the user hasn't allowed Automation for this player.
            if code == -1743 || code == -10004 { return .denied }
            log.debug("AppleScript error \(code)")
            return .failed
        }
        return .output(descriptor.stringValue ?? "")
    }

    static func runData(_ source: String) -> DataResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed }
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil, !descriptor.data.isEmpty else { return .failed }
        return .data(descriptor.data)
    }
}

enum Scripts {
    private static let sep = "(character id 31)"

    /// Checked inside the script, at the moment it runs: a player that quit between the
    /// Swift check and the script must not be relaunched by `tell application`.
    private static func ifRunning(_ id: String, _ body: String) -> String {
        "if application id \"\(id)\" is running then\n\(body)\nend if\nreturn \"stopped\""
    }

    static let spotifyState = ifRunning("com.spotify.client", """
    tell application id "com.spotify.client"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set sep to \(sep)
        return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (track number of t) & sep & (disc number of t) & sep & (duration of t) & sep & (player position) & sep & (id of t) & sep & (artwork url of t)
    end tell
    """)

    static let musicState = ifRunning("com.apple.Music", """
    tell application id "com.apple.Music"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set sep to \(sep)
        set dn to 1
        try
            set dn to disc number of t
        end try
        set al to ""
        try
            set al to album of t
        end try
        return s & sep & (name of t) & sep & (artist of t) & sep & al & sep & (track number of t) & sep & dn & sep & (duration of t) & sep & (player position) & sep & (persistent ID of t)
    end tell
    """)

    static let musicArtwork = ifRunning("com.apple.Music", """
    tell application id "com.apple.Music"
        return data of artwork 1 of current track
    end tell
    """)

    /// Library tracks of an album, offline: the track list comes from your Music library.
    static func musicAlbum(_ album: String) -> String {
        let escaped = album.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ifRunning("com.apple.Music", """
        tell application id "com.apple.Music"
            set sep to \(sep)
            set rs to (character id 30)
            set out to ""
            set ts to (every track of library playlist 1 whose album is "\(escaped)")
            repeat with t in ts
                set dn to 1
                try
                    set dn to disc number of t
                end try
                set out to out & (track number of t) & sep & dn & sep & (duration of t) & sep & (name of t) & sep & (artist of t) & rs
            end repeat
            return out
        end tell
        """)
    }
}

// MARK: - Apple catalog (opt-in)

/// Optional and off by default: asks Apple's public iTunes Search API for an
/// album's track list when it isn't in the local library.
enum CatalogLookup {
    struct Found { var tracks: [LPTrack]; var artwork: URL? }

    static func album(artist: String, title: String) -> Found? {
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [.init(name: "term", value: "\(artist) \(title)"),
                             .init(name: "entity", value: "album"), .init(name: "limit", value: "10")]
        guard let url = search.url, let json = fetchJSON(url),
              let results = json["results"] as? [[String: Any]] else { return nil }
        let wanted = title.lowercased()
        let best = results.first { ($0["collectionName"] as? String)?.lowercased() == wanted }
            ?? results.first { (($0["collectionName"] as? String)?.lowercased().hasPrefix(wanted)) ?? false }
        guard let id = best?["collectionId"] as? Int,
              let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(id)&entity=song"),
              let lookup = fetchJSON(lookupURL), let items = lookup["results"] as? [[String: Any]] else { return nil }
        let tracks = items.compactMap { item -> LPTrack? in
            guard item["wrapperType"] as? String == "track",
                  let name = item["trackName"] as? String, let ms = item["trackTimeMillis"] as? Double else { return nil }
            return LPTrack(title: name, duration: ms / 1000, number: item["trackNumber"] as? Int ?? 0,
                           disc: item["discNumber"] as? Int ?? 1)
        }.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
        let art = (best?["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100", with: "1000x1000")
        return tracks.isEmpty ? nil : Found(tracks: tracks, artwork: art.flatMap(URL.init(string:)))
    }

    private static func fetchJSON(_ url: URL) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return result
    }
}
