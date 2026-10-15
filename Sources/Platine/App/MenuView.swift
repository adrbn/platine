import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar popover: what's on the platter, then the room, then the view.
struct MenuView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = PlaybackStore.shared
    var desktopOn: Bool
    var toggleDesktop: () -> Void
    var openPreview: () -> Void
    var openSettings: () -> Void
    var openAutomation: () -> Void

    @State private var cities = CityViews.all()
    @State private var query = ""
    @State private var searching = false
    @State private var status: String?
    @State private var attempt = 0
    @FocusState private var searchFocused: Bool
    @State private var blur: Double = Settings.shared.viewBlur

    static let amber = Color(red: 0.878, green: 0.635, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            nowPlaying
            section("Framing") { framings }
            section("Light") { light }
            section("Through the window") { window }
            section("Rain on the window") {
                Picker("", selection: $settings.rainMode) {
                    ForEach(RainMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(18)
        .frame(width: 340)
        .tint(Self.amber)
        .onAppear { cities = CityViews.all() }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Group {
                if let art = store.album?.artwork {
                    Image(decorative: art, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.06)
                        Image(systemName: "record.circle").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                if let track = store.snapshot?.track {
                    Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(track.artist), \(store.album?.title ?? track.album)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Text(sideLine).font(.system(size: 11)).foregroundStyle(Self.amber.opacity(0.9)).lineLimit(1)
                } else {
                    Text("Nothing on the platter").font(.system(size: 13, weight: .semibold))
                    Text("Play something in Spotify or Music.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(store.automationDenied.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                    Button("Allow Platine to read \(source == .spotify ? "Spotify" : "Music")…", action: openAutomation)
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var sideLine: String {
        let paused = store.snapshot?.state == .playing ? "" : "Paused, "
        guard let album = store.album, let index = store.trackIndex,
              let (side, _) = album.layout.band(forTrack: index) else { return paused + "33⅓ rpm" }
        let speed = album.layout.isSingle ? "45 rpm" : "33⅓ rpm"
        return "\(paused)Side \(album.layout.sides[side].letter) of \(album.layout.sides.count), \(speed)"
    }

    // MARK: Room

    private var framings: some View {
        HStack(spacing: 8) {
            ForEach(Framing.allCases) { f in
                Button { settings.framing = f } label: {
                    VStack(spacing: 5) {
                        Group {
                            if let thumb = Thumbnails.plate(f) {
                                Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(width: 70, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(settings.framing == f ? Self.amber : .white.opacity(0.08),
                                          lineWidth: settings.framing == f ? 2 : 1))
                        Text(f.title).font(.system(size: 11))
                            .foregroundStyle(settings.framing == f ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let hours: [(hour: Double?, symbol: String, name: String)] = [
        (nil, "clock", "Now"), (7.5, "sunrise", "Morning"), (12.5, "sun.max", "Noon"),
        (17.3, "sun.haze", "Five"), (19.2, "sunset", "Dusk"), (22, "moon.stars", "Night"),
    ]

    private var light: some View {
        HStack(spacing: 0) {
            ForEach(Self.hours, id: \.name) { h in
                let on = settings.hourOverride == h.hour
                Button { settings.hourOverride = h.hour } label: {
                    VStack(spacing: 4) {
                        Image(systemName: h.symbol).font(.system(size: 15)).frame(height: 18)
                        Text(h.name).font(.system(size: 10))
                    }
                    .foregroundStyle(on ? Self.amber : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Self.amber.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(h.hour == nil ? "Follow the clock" : h.name)
            }
        }
    }

    // MARK: The view

    private var matches: [CityView] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = cities.filter { $0.name.range(of: q, options: opts) != nil }
        // Names that start with what you typed come first.
        let starts = hits.filter { $0.name.range(of: q, options: opts.union(.anchored)) != nil }
        return (starts + hits.filter { !starts.contains($0) }).prefix(5).map { $0 }
    }

    private var window: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(CityViews.find(settings.viewCity)?.name ?? "Search a city", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = matches.first { pick(first) } else { find(attempt: 0) } }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))

            if !query.isEmpty {
                ForEach(matches) { city in
                    row(city.name, symbol: city.id == settings.viewCity ? "checkmark" : "building.2") { pick(city) }
                }
                let exact = matches.contains { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                if !exact && !searching {
                    row("Find free photos of “\(query)”", symbol: "globe") { find(attempt: 0) }
                }
            } else if let city = CityViews.find(settings.viewCity) {
                HStack {
                    Text(city.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if city.id.hasPrefix("custom-") && !searching {
                        Button("Another photo") { find(attempt: attempt + 1, name: city.name) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Self.amber)
                    }
                }
                Text(city.creditLine).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("Sharp").font(.system(size: 10)).foregroundStyle(.tertiary)
                // Re-blurring the photo takes a moment: applied when you let go.
                Slider(value: $blur, in: 0...2) { editing in if !editing { settings.viewBlur = blur } }
                    .controlSize(.mini)
                Text("Soft").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .help("How blurred the view behind the window is")
            row("Use your own photo…", symbol: "photo") { importPhoto() }
            if searching {
                Text("Asking Openverse for free photos… this can take a moment.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let status {
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ city: CityView) {
        settings.viewCity = city.id
        query = ""
        status = nil
    }

    private func importPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "A wide photo works best: a view, a landscape, a skyline."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let view = try CityViews.importPhoto(url)
            cities = CityViews.all()
            settings.viewCity = view.id
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    /// Free photos of any place, from Openverse: a day and a night one.
    private func find(attempt: Int, name: String? = nil) {
        let name = name ?? query
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        status = nil
        Task {
            defer { searching = false }
            do {
                let view = try await CityViews.search(name, attempt: attempt)
                self.attempt = attempt
                cities = CityViews.all()
                settings.viewCity = view.id      // publishes even when unchanged: the room reloads the new photo
                query = ""
            } catch {
                status = error.localizedDescription
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("On the desktop", isOn: Binding(get: { desktopOn }, set: { _ in toggleDesktop() }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
            Spacer()
            footerButton("macwindow", "Preview window", openPreview)
            footerButton("gearshape", "Settings", openSettings).keyboardShortcut(",")
            footerButton("power", "Quit Platine") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }

    private func footerButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
}

/// Small copies of the plates, for the framing tiles.
@MainActor
enum Thumbnails {
    private static var cache: [String: CGImage] = [:]

    static func plate(_ framing: Framing) -> CGImage? {
        let tag = PlateSchedule.blend(atHour: Settings.shared.plateHour).from
        let name = "\(framing.rawValue)-\(tag)"
        if let hit = cache[name] { return hit }
        guard let dir = PlateLibrary.bundled?.directory,
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("\(name).heic") as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary)
        else { return nil }
        cache[name] = img
        return img
    }
}
