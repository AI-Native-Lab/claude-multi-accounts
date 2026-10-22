import AppKit
import ServiceManagement

/// The person's choices, kept in the app's preferences. The demo keeps its own copy, so trying
/// the demo never changes the real app's settings.
@MainActor
final class AppSettings: ObservableObject {
    private enum Key {
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showDockIcon = "showDockIcon"
        static let showNameInMenuBar = "showNameInMenuBar"
        static let askBeforeSwitching = "askBeforeSwitching"
        static let reopenAfterUpdates = "reopenAfterUpdates"
    }

    private let defaults: UserDefaults
    private let isDemo: Bool
    private var demoOpenAtLogin = false

    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) }
    }
    /// Shows the main Claude's account next to the menu bar icon.
    @Published var showNameInMenuBar: Bool {
        didSet { defaults.set(showNameInMenuBar, forKey: Key.showNameInMenuBar) }
    }
    /// Switching quits Claude, which stops running Code sessions, so it asks first.
    @Published var askBeforeSwitching: Bool {
        didSet { defaults.set(askBeforeSwitching, forKey: Key.askBeforeSwitching) }
    }
    /// Claude quits an idle window to install an update and its updater reopens only the main
    /// Claude, so the app reopens the rest.
    @Published var reopenAfterUpdates: Bool {
        didSet { defaults.set(reopenAfterUpdates, forKey: Key.reopenAfterUpdates) }
    }

    init(isDemo: Bool) {
        self.isDemo = isDemo
        defaults = isDemo ? UserDefaults(suiteName: "local.claude-account-swap.demo") ?? .standard : .standard
        defaults.register(defaults: [Key.showMenuBarIcon: true, Key.showDockIcon: true,
                                     Key.showNameInMenuBar: true, Key.askBeforeSwitching: true,
                                     Key.reopenAfterUpdates: true])
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        showNameInMenuBar = defaults.bool(forKey: Key.showNameInMenuBar)
        askBeforeSwitching = defaults.bool(forKey: Key.askBeforeSwitching)
        reopenAfterUpdates = defaults.bool(forKey: Key.reopenAfterUpdates)
    }

    var openAtLogin: Bool {
        isDemo ? demoOpenAtLogin : SMAppService.mainApp.status == .enabled
    }

    func setOpenAtLogin(_ on: Bool) throws {
        objectWillChange.send()
        if isDemo {
            demoOpenAtLogin = on
        } else if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
