import AppKit

/// Small modal dialogs. Each one brings the app to the front first, since it may be running
/// without a window.
@MainActor
enum Prompt {
    /// Asks for a line of text. Returns nil when cancelled; an empty answer is allowed only with
    /// `allowEmpty` (the caller then picks a default).
    static func text(title: String, message: String, placeholder: String, initial: String = "",
                     button: String = "OK", allowEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty && !allowEmpty ? nil : value
    }

    /// Asks to go ahead. With `suppressible`, the alert has a "Don't ask again" box, reported in
    /// `dontAskAgain`.
    static func confirm(title: String, message: String, button: String,
                        suppressible: Bool = false, dontAskAgain: UnsafeMutablePointer<Bool>? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = suppressible
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert.runModal() == .alertFirstButtonReturn
        dontAskAgain?.pointee = ok && alert.suppressionButton?.state == .on
        return ok
    }

    static func info(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func error(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Claude Multi-Accounts"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
