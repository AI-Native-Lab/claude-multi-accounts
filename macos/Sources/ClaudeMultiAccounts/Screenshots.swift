import AppKit
import SwiftUI

/// Draws the README screenshots from the demo data: real app windows, rendered off screen.
@MainActor
enum Screenshots {
    static func render(model: AppModel, settings: AppSettings, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.refreshNow()
        let size = NSSize(width: 840, height: 570)

        for (name, appearance) in [("main-window", NSAppearance.Name.aqua), ("main-window-dark", .darkAqua)] {
            try await snapshot(MainView(model: model, settings: settings), size: size, title: "Claude Multi-Accounts",
                               appearance: appearance, to: folder.appendingPathComponent("\(name).png"))
        }

        try await snapshot(SettingsView(model: model, settings: settings, showsDoneButton: false),
                           size: NSSize(width: 560, height: 1070), title: "Settings",
                           appearance: .aqua, to: folder.appendingPathComponent("settings.png"))
    }

    /// Draws as the active window, so buttons and switches have their normal colours.
    private final class ActiveWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    /// Puts a view in a window off screen and saves the window, title bar included, as a PNG.
    private static func snapshot<Content: View>(_ view: Content, size: NSSize, title: String,
                                                appearance: NSAppearance.Name, to url: URL) async throws {
        let window = ActiveWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: appearance)
        // Off screen the window never becomes key, so switches would draw grey; draw them as active.
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .environment(\.controlActiveState, .key))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // Controls only draw in their active colours while the app itself is in front.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 800_000_000)

        guard let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        print("Wrote \(url.path)")
    }
}
