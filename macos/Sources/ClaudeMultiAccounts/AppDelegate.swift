import AppKit
import MultiAccountsCore
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum Mode {
        case normal
        case demo
        case screenshots(URL)
    }

    private let mode: Mode
    private var settings: AppSettings!
    private var model: AppModel!
    private var window: NSWindow?
    private var statusMenu: StatusMenuController?
    private var observations: Set<AnyCancellable> = []

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDemo: Bool
        let manager: AccountManager
        switch mode {
        case .normal:
            isDemo = false
            manager = AccountManager()
        case .demo, .screenshots:
            isDemo = true
            do {
                manager = try Demo.makeManager()
            } catch {
                Prompt.error(error)
                NSApp.terminate(nil)
                return
            }
        }
        settings = AppSettings(isDemo: isDemo)
        model = AppModel(manager: manager, settings: settings, isDemo: isDemo)

        if case .screenshots(let folder) = mode {
            NSApp.setActivationPolicy(.accessory)
            Task {
                do {
                    try await Screenshots.render(model: model, settings: settings, into: folder)
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return
        }

        NSApp.mainMenu = MainMenu.make()
        model.start()
        statusMenu = StatusMenuController(model: model, settings: settings,
                                          openWindow: { [weak self] in self?.showMainWindow(nil) },
                                          openSettings: { [weak self] in self?.showSettings(nil) })

        settings.$showDockIcon
            .sink { [weak self] show in self?.applyDockIcon(show) }
            .store(in: &observations)
        settings.$showMenuBarIcon
            .sink { [weak self] show in self?.statusMenu?.setVisible(show) }
            .store(in: &observations)

        if !launchedAtLogin() { showMainWindow(nil) }
    }

    /// Clicking the Dock icon, or opening the app again from Finder, Launchpad or Spotlight.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        statusMenu?.dockMenu()
    }

    @objc func showMainWindow(_ sender: Any?) {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        showMainWindow(nil)
        model.showingSettings = true
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Keep all your Claude accounts signed in and use them at the same time, each in its own Claude window. No logging out and back in.\n\nAn independent project, not affiliated with or endorsed by Anthropic.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.isDemo ? "Claude Multi-Accounts — Demo" : "Claude Multi-Accounts"
        window.contentView = NSHostingView(rootView: MainView(model: model, settings: settings))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName(model.isDemo ? "DemoWindow" : "MainWindow")
        return window
    }

    private func applyDockIcon(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Leaving the Dock deactivates the app; keep the window in front if it is open.
        if !show, window?.isVisible == true {
            DispatchQueue.main.async { self.showMainWindow(nil) }
        }
    }

    /// When the Mac starts the app at login, it runs in the menu bar without a window.
    private func launchedAtLogin() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        return settings.openAtLogin && ProcessInfo.processInfo.systemUptime < 300
    }
}
