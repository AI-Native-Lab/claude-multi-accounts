import AppKit
import MultiAccountsCore
import Combine

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// The menu bar item and the Dock icon's menu. Both are rebuilt from the model each time they open.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let settings: AppSettings
    private let openWindow: () -> Void
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var observations: Set<AnyCancellable> = []

    init(model: AppModel, settings: AppSettings, openWindow: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.model = model
        self.settings = settings
        self.openWindow = openWindow
        self.openSettings = openSettings
        super.init()
        for publisher in [model.objectWillChange, settings.objectWillChange] {
            publisher.sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
                .store(in: &observations)
        }
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            item.menu = menu
            self.item = item
            updateButton()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addAccounts(to: menu)
        return menu
    }

    private func updateButton() {
        guard let button = item?.button else { return }
        let symbol = model.busy != nil ? "hourglass"
            : model.statuses.contains(where: \.isSignedInTwice) ? "exclamationmark.triangle"
            : model.statuses.contains(where: { $0.place == .window }) ? "rectangle.split.2x1"
            : "person.2.circle"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Multi-Accounts")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        let name = settings.showNameInMenuBar ? model.mainName.map { " \($0)" } ?? "" : ""
        button.title = model.isDemo ? " Demo ·\(name)" : name
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(ActionItem(model.busy ?? model.headline, enabled: false) {})
        if model.busy == nil, !model.subheadline.isEmpty {
            menu.addItem(ActionItem(model.subheadline, enabled: false) {})
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Open Claude Multi-Accounts…") { [openWindow] in openWindow() })
        menu.addItem(.separator())
        addAccounts(to: menu)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Settings…") { [openSettings] in openSettings() })
        menu.addItem(ActionItem("Quit Claude Multi-Accounts") { NSApp.terminate(nil) })
    }

    /// The accounts, to open side by side with one click, then switching the main Claude.
    private func addAccounts(to menu: NSMenu) {
        let idle = model.busy == nil && model.snapshot != nil
        menu.addItem(ActionItem("Open Side by Side", enabled: false) {})
        if model.statuses.isEmpty {
            menu.addItem(ActionItem("No saved accounts yet", enabled: false) {})
        }
        for status in model.statuses {
            let expired = status.place == .saved && status.loginExpires == nil
            var title = status.account.name
            switch status.place {
            case .main: title += "  (main Claude)"
            case .window: title += "  (own window)"
            case .saved where expired: title += "  (sign-in expired)"
            case .notSaved: title += "  (not saved yet)"
            default: break
            }
            // Ticked when open; a click brings it forward, or opens a saved one in its own window.
            let open = status.place == .main || status.place == .window
            menu.addItem(ActionItem(title, enabled: idle && (open || (status.place == .saved && !expired)), checked: open) { [model] in
                switch status.place {
                case .main: model.openMain()
                case .window: model.showWindow(status)
                default: model.openWindow(status)
                }
            })
        }
        menu.addItem(ActionItem("Sign In to Another Account in a New Window…", enabled: idle) { [model] in model.addInWindow() })
        let windows = model.statuses.filter { $0.place == .window }
        if !windows.isEmpty {
            let close = NSMenu()
            close.autoenablesItems = false
            for status in windows {
                close.addItem(ActionItem(status.account.name) { [model] in model.closeWindow(status) })
            }
            menu.addItem(Self.submenu("Close Window", close, enabled: idle))
        }

        let switching = NSMenu()
        switching.autoenablesItems = false
        if model.statuses.isEmpty {
            switching.addItem(ActionItem("No saved accounts yet", enabled: false) {})
        }
        for status in model.statuses {
            var title = status.account.name
            switch status.place {
            case .window: title += "  (in its own window)"
            case .saved where status.loginExpires == nil: title += "  (sign-in expired)"
            case .notSaved: title += "  (not saved yet)"
            default: break
            }
            let usable = status.place == .main || status.hasSavedSignIn
            switching.addItem(ActionItem(title, enabled: usable, checked: status.place == .main) { [model] in
                model.switchTo(status)
            })
        }
        switching.addItem(.separator())
        switching.addItem(ActionItem("Sign In to Another Account (Restarts Claude)…") { [model] in model.addInMain() })
        menu.addItem(.separator())
        menu.addItem(Self.submenu("Switch Main Claude", switching, enabled: idle))
    }

    private static func submenu(_ title: String, _ submenu: NSMenu, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = enabled
        return item
    }
}

/// The app's menus at the top of the screen while it shows in the Dock.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Claude Multi-Accounts", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Claude Multi-Accounts", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Claude Multi-Accounts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "Claude Multi-Accounts", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Claude Multi-Accounts", action: #selector(AppDelegate.showMainWindow(_:)), keyEquivalent: "0")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }
}
