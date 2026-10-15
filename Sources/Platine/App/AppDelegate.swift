import AppKit
import ServiceManagement
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let settings = Settings.shared
    private let store = PlaybackStore.shared
    private let bridge = PlayerBridge()
    private let desktop = DesktopController()
    private var statusItem: NSStatusItem!
    private var previewWindow: NSWindow?
    private var previewRoom: RoomView?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--snapshot") {
            Snapshot.run(arguments: args)
            exit(0)
        }

        store.restoreFromDisk()
        bridge.start()
        Weather.shared.start()
        Locator.shared.start()
        desktop.start()
        setUpStatusItem()
        // Scriptable framing, for tests and Shortcuts: post com.adrbn.platine.framing with "close", "above"...
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.adrbn.platine.framing"),
                                                            object: nil, queue: .main) { note in
            guard let f = (note.object as? String).flatMap(Framing.init(rawValue:)) else { return }
            MainActor.assumeIsolated { Settings.shared.framing = f }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.adrbn.platine.menu"),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePopover() }
        }
        if args.contains("--window") { openPreview() }
        if args.contains("--menu") {
            // For tests: the popover's content in a plain window (a hidden menu bar can't anchor a popover).
            let w = NSWindow(contentViewController: NSHostingController(rootView: menuView))
            w.appearance = NSAppearance(named: .darkAqua)
            w.title = "Platine Menu"
            w.center()
            w.orderFrontRegardless()
            settingsWindow = w
        }
    }

    // MARK: Menu bar

    private var popover: NSPopover?

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Platine")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
    }

    @objc func togglePopover() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let p = NSPopover()
        p.behavior = .transient
        p.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: menuView)
        host.sizingOptions = .preferredContentSize
        // Measured before showing: a popover that grows after opening grows upward, off the screen.
        p.contentSize = host.view.fittingSize
        p.contentViewController = host
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        popover = p
    }

    private var menuView: MenuView {
        MenuView(desktopOn: desktop.isRunning,
                 toggleDesktop: { [weak self] in self?.toggleDesktop() },
                 openPreview: { [weak self] in self?.popover?.performClose(nil); self?.openPreview() },
                 openSettings: { [weak self] in self?.popover?.performClose(nil); self?.openSettings() },
                 openAutomation: { [weak self] in self?.openAutomationSettings() })
    }

    private func toggleDesktop() {
        if desktop.isRunning { desktop.stop() } else { desktop.start() }
        (popover?.contentViewController as? NSHostingController<MenuView>)?.rootView = menuView
    }

    private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    // MARK: Windows

    @objc func openPreview() {
        if let previewWindow { previewWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Platine"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let room = RoomView(frame: frame)
        window.contentView = room.view
        room.start()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
        previewRoom = room
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Platine Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === previewWindow else { return }
        previewRoom?.stop()
        previewRoom = nil
        previewWindow = nil
    }
}
