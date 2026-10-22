import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// Drawn on its own for the screenshots, without the Done button's sheet.
    var showsDoneButton = true

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Where to find Claude Multi-Accounts") {
                    Toggle("Show in the Dock", isOn: $settings.showDockIcon)
                    Toggle("Show in the menu bar", isOn: $settings.showMenuBarIcon)
                    Toggle("Show the main Claude's account next to the menu bar icon", isOn: $settings.showNameInMenuBar)
                        .disabled(!settings.showMenuBarIcon)
                    Text("On a MacBook with a notch, menu bar icons can hide behind it when the menu bar is full. The app can always be opened from the Dock, Launchpad or Spotlight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !settings.showDockIcon && !settings.showMenuBarIcon {
                        Label("Both icons are off. Open Claude Multi-Accounts from Launchpad, Spotlight or the Applications folder to get back to this window.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("Startup") {
                    Toggle("Open Claude Multi-Accounts at login", isOn: Binding(
                        get: { settings.openAtLogin },
                        set: { on in
                            do { try settings.setOpenAtLogin(on) } catch { Prompt.error(error) }
                        }))
                    Text("Opened at login, it waits in the menu bar without showing its window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Switching") {
                    Toggle("Ask before switching the main Claude", isOn: $settings.askBeforeSwitching)
                    Text("Switching quits the main Claude, which stops Code sessions that are running. Opening an account side by side never restarts it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Command line") {
                    LabeledContent("claude-multi-accounts") {
                        if model.commandInstalled {
                            Text("Installed in ~/.local/bin").foregroundStyle(.secondary)
                        } else {
                            Button("Install in ~/.local/bin") { model.installCommand() }
                        }
                    }
                    Text("The same commands for Terminal and scripts: list, open, close, add, switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Data") {
                    LabeledContent("Saved accounts") {
                        Button("Show in Finder") { model.showAccountsFolder() }
                    }
                    LabeledContent("Claude's data folder") {
                        Button("Show in Finder") { model.showClaudeDataFolder() }
                    }
                    LabeledContent("Activity log") {
                        Button("Open") { model.openLog() }
                    }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                    Text("Claude Multi-Accounts is an independent project, not affiliated with or endorsed by Anthropic.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if showsDoneButton {
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { model.showingSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
        }
        .frame(width: 560, height: showsDoneButton ? 660 : 900)
    }
}
