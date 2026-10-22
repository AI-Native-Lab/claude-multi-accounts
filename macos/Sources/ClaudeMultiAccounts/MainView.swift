import MultiAccountsCore
import SwiftUI

/// The main window: the account in the main Claude, every saved account, and what can be done with each.
struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    banners
                    if model.snapshot != nil && model.statuses.isEmpty {
                        Text("No saved accounts yet. Use “Add Account” to sign in to another one in its own window.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 40)
                    }
                    ForEach(model.statuses) { status in
                        AccountRow(model: model, status: status)
                    }
                    Text("Every account stays signed in. Open Side by Side runs an account in its own Claude window, with its session history, next to the main Claude, so you can use both at once. Switch puts an account in the main Claude instead, which restarts in a few seconds; Code sessions that are running stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 660, minHeight: 480)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView(model: model, settings: settings)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline)
                    .font(.title2.weight(.semibold))
                Text(model.subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Menu {
                Button("Sign In in a New Window…") { model.addInWindow() }
                Button("Sign In in the Main Claude (Restarts It)…") { model.addInMain() }
            } label: {
                Label("Add Account", systemImage: "plus")
            } primaryAction: {
                model.addInWindow()
            }
            .fixedSize()
            .disabled(model.busy != nil || model.snapshot == nil)
            Button {
                model.showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var banners: some View {
        if model.isDemo {
            Banner(symbol: "theatermasks", tint: .blue,
                   text: "Demo with synthetic accounts. Everything happens in a temporary folder; the real Claude on this Mac is never touched.")
        }
        if let problem = model.problem {
            Banner(symbol: "exclamationmark.triangle", tint: .orange, text: problem)
        }
        if model.snapshot?.mainIsUnnamed == true {
            Banner(symbol: "person.crop.circle.badge.questionmark", tint: .orange,
                   text: "Claude is signed in to an account this app hasn't named yet.") {
                Button("Name It…") { model.nameMainAccount() }
            }
        }
        if let twice = model.statuses.first(where: \.isSignedInTwice) {
            Banner(symbol: "exclamationmark.circle", tint: .orange,
                   text: "“\(twice.account.name)” is signed in both in the main Claude and in its own window. Close that window before switching.") {
                Button("Close Window") { model.closeWindow(twice) }
            }
        }
        ForEach(model.snapshot?.newWindows ?? []) { window in
            let who = window.name.map { "“\($0)”" } ?? "another account"
            if window.pid != nil {
                Banner(symbol: "macwindow.badge.plus", tint: .blue,
                       text: "A new Claude window is open to sign in to \(who). It joins this list once signed in.") {
                    Button("Show") { model.openNewWindow(window) }
                    Button("Close") { model.closeNewWindow(window) }
                }
            } else {
                Banner(symbol: "macwindow", tint: .gray,
                       text: "The window to sign in to \(who) was closed before signing in.") {
                    Button("Open Again") { model.openNewWindow(window) }
                    Button("Discard") { model.discardNewWindow(window) }
                }
            }
        }
        if let busy = model.busy {
            Banner(symbol: nil, tint: .accentColor, text: busy)
        }
    }
}

/// One saved account.
struct AccountRow: View {
    @ObservedObject var model: AppModel
    let status: AccountStatus

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: status.account.name)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(status.account.name).font(.headline)
                    badge
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlight ?? Color.primary.opacity(0.08), lineWidth: highlight == nil ? 1 : 1.5)
        )
    }

    private var highlight: Color? {
        switch status.place {
        case .main: return Color.accentColor.opacity(0.7)
        case .window: return Color.blue.opacity(0.45)
        default: return nil
        }
    }

    private var expired: Bool { status.place != .notSaved && status.loginExpires == nil }

    private var badge: some View {
        let (text, color): (String, Color) = {
            switch status.place {
            case .main: return status.isSignedInTwice ? ("Main Claude · also in a window", .orange) : ("Main Claude", .green)
            case .window: return ("Own window", .blue)
            case .saved: return expired ? ("Sign-in expired", .orange) : ("Saved", .gray)
            case .notSaved: return ("Not saved yet", .orange)
            }
        }()
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var details: String {
        var parts: [String] = []
        switch status.place {
        case .notSaved:
            parts.append("Saved the first time the main Claude switches away from it")
        case .saved where expired:
            parts.append("Switch to it, then sign in again")
        default:
            parts.append("Signed in \(AppModel.describe(status.loginExpires))")
        }
        if status.place == .saved, let saved = status.account.savedDate {
            let formatter = RelativeDateTimeFormatter()
            parts.append("saved \(formatter.localizedString(for: saved, relativeTo: Date()))")
        }
        if status.place != .main, let size = model.sizes[status.account.uuid] {
            parts.append(Disk.format(size))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch status.place {
            case .main:
                Button(model.snapshot?.main.running == true ? "Show Claude" : "Open Claude") { model.openMain() }
            case .window:
                Button("Show") { model.showWindow(status) }
                Button("Close Window") { model.closeWindow(status) }
            case .saved:
                Button("Open Side by Side") { model.openWindow(status) }
                    .buttonStyle(.borderedProminent)
                    .disabled(expired)
                Button("Switch") { model.switchTo(status) }
            case .notSaved:
                EmptyView()
            }
            Menu {
                if status.place == .saved || status.place == .window {
                    Button("Switch Main Claude to This Account") { model.switchTo(status) }
                    Divider()
                }
                Button("Rename…") { model.rename(status) }
                Button("Show Folder in Finder") { model.showFolder(status) }
                    .disabled(!FileManager.default.fileExists(atPath: status.folder.path))
                Divider()
                Button("Remove…") { model.remove(status) }
                    .disabled(status.place == .main || status.place == .window)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .disabled(model.busy != nil)
    }
}

/// A notice above the accounts.
struct Banner<Trailing: View>: View {
    let symbol: String?
    let tint: Color
    let text: String
    let trailing: Trailing

    init(symbol: String?, tint: Color, text: String, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
    }
}

extension Banner where Trailing == EmptyView {
    init(symbol: String?, tint: Color, text: String) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

/// A round badge with the account's initials, in a colour that stays the same for a name.
struct Avatar: View {
    let name: String

    private static let colors: [Color] = [
        Color(red: 0.85, green: 0.47, blue: 0.34), .teal, .indigo, .pink, .purple, .green, .blue, .orange,
    ]

    var body: some View {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        let initials = [words.first, words.count > 1 ? words.last : nil]
            .compactMap { $0?.first.map { String($0).uppercased() } }
            .joined()
        let index = name.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 } % Self.colors.count
        return Text(initials)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(Circle().fill(Self.colors[index].gradient))
    }
}
