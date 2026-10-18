import AppKit
import Combine
import SceneKit

/// A borderless window at desktop level: behind the icons, on every Space,
/// click-through, never key.
final class WallpaperWindow: NSWindow {
    static let desktopBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        canHide = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Just under the icons: macOS 27 lays a wallpaper-drawing backdrop over the desktop level.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        collectionBehavior = Self.desktopBehavior
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One room, one view, one director. Used for wallpapers and the preview window.
@MainActor
final class RoomView {
    let room = RoomScene()
    let view: SCNView
    let director: RecordDirector
    private var cancellables: Set<AnyCancellable> = []
    private var environmentTimer: Timer?

    init(frame: NSRect) {
        view = SCNView(frame: frame, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        director = RecordDirector(room: room)
        view.scene = room.scene
        view.pointOfView = room.cameraNode
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        view.delegate = director
        view.isPlaying = true
        view.rendersContinuously = false
        view.autoresizingMask = [.width, .height]
        if let plates = PlateLibrary.bundled {
            room.plateState.aspect = frame.width / max(1, frame.height)
            room.usePlates(plates)
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: view)
                .sink { [weak self] _ in self?.fitPlates() }
                .store(in: &cancellables)
        }
    }

    /// The plate is cropped to the view; a resized preview window needs a new crop and field of view.
    private func fitPlates() {
        let b = view.bounds
        guard b.height > 0, abs(room.plateState.aspect - b.width / b.height) > 0.005 else { return }
        room.plateState.aspect = b.width / b.height
        room.setFraming(room.framing, animated: false)
        updateEnvironment()
    }

    func start() {
        let settings = Settings.shared, weather = Weather.shared
        director.start()
        view.preferredFramesPerSecond = settings.frameRate
        room.setFraming(settings.framing, animated: false)

        settings.$framing.dropFirst().sink { [weak self] in
            // One transaction: the camera and the plate behind it land on the same frame.
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            self?.room.setFraming($0, animated: false)
            self?.updateEnvironment()
            SCNTransaction.commit()
        }.store(in: &cancellables)
        // The pile's cover can arrive late (fetched after launch).
        PlaybackStore.shared.$previousAlbum.dropFirst().compactMap { $0 }.removeDuplicates().sink { [weak self] p in
            self?.room.setPileCover(p.artwork, title: p.title, artist: p.artist)
        }.store(in: &cancellables)
        settings.$viewBlur.sink { [weak self] blur in
            self?.room.plateState.library?.viewBlur = blur
            self?.room.plateState.lastKey = ""
            self?.updateEnvironment()
        }.store(in: &cancellables)
        settings.$frameRate.sink { [weak self] in self?.view.preferredFramesPerSecond = $0 }.store(in: &cancellables)
        settings.$viewCity.sink { [weak self] id in
            self?.room.setCity(CityViews.find(id))
            self?.updateEnvironment()
        }.store(in: &cancellables)
        Publishers.CombineLatest4(settings.$rainMode, settings.$hourOverride, weather.$forecastRain, weather.$cloudCover)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateEnvironment() }
            .store(in: &cancellables)
        environmentTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateEnvironment() }
        }
        updateEnvironment()
    }

    func updateEnvironment() {
        let settings = Settings.shared, weather = Weather.shared
        let hour = settings.plateHour
        let rain = weather.rainLevel(for: settings.rainMode)
        room.updateEnvironment(hour: hour, rain: rain, cloud: settings.rainMode == .automatic ? weather.cloudCover : 0)
    }

    /// Stop drawing entirely when nothing of the desktop is visible.
    func setPaused(_ paused: Bool) {
        view.isPlaying = !paused
        room.scene.isPaused = paused
    }

    func stop() {
        director.stop()
        environmentTimer?.invalidate()
        cancellables.removeAll()
        view.isPlaying = false
    }
}

/// Puts a room behind the icons of the main display (or every display).
@MainActor
final class DesktopController {
    private var windows: [(WallpaperWindow, RoomView)] = []
    private let occlusion = OcclusionDetector()
    private var cancellables: Set<AnyCancellable> = []
    private(set) var isRunning = false
    private var covered = false
    private var away = false    // display asleep or screen locked

    private func applyPause() { windows.forEach { $0.1.setPaused(covered || away) } }

    func start() {
        let settings = Settings.shared
        isRunning = true
        rebuild()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        settings.$allDisplays.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }.store(in: &cancellables)
        occlusion.onChange = { [weak self] covered in
            self?.covered = covered
            self?.applyPause()
        }
        let ws = NSWorkspace.shared.notificationCenter, dist = DistributedNotificationCenter.default()
        for (center, name, isAway) in [(ws, NSWorkspace.screensDidSleepNotification, true),
                                       (ws, NSWorkspace.screensDidWakeNotification, false),
                                       (dist, Notification.Name("com.apple.screenIsLocked"), true),
                                       (dist, Notification.Name("com.apple.screenIsUnlocked"), false)] {
            center.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.away = isAway; self?.applyPause() }
                .store(in: &cancellables)
        }
        occlusion.start()
        // Space membership settles after launch; re-assert it once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.windows.forEach { $0.0.collectionBehavior = WallpaperWindow.desktopBehavior; $0.0.orderFrontRegardless() }
        }
    }

    func stop() {
        isRunning = false
        occlusion.stop()
        cancellables.removeAll()
        tearDown()
    }

    private func tearDown() {
        for (w, r) in windows { r.stop(); w.orderOut(nil); w.close() }
        windows.removeAll()
    }

    private func rebuild() {
        guard isRunning else { return }
        tearDown()
        let screens = Settings.shared.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let window = WallpaperWindow(screen: screen)
            let room = RoomView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = room.view
            room.start()
            window.orderFrontRegardless()
            windows.append((window, room))
        }
        covered = occlusion.currentlyOccluded
        applyPause()
    }
}
