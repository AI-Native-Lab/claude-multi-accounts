import XCTest
@testable import MultiAccountsCore

final class AccountManagerTests: XCTestCase {
    var root: URL!
    var layout: Layout!
    var claude: SimulatedClaude!
    var manager: AccountManager!
    let fm = FileManager.default
    let uuidA = "aaaaaaaa-0000-4000-8000-000000000001"
    let uuidB = "bbbbbbbb-0000-4000-8000-000000000002"
    let uuidC = "cccccccc-0000-4000-8000-000000000003"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("claude-swap-tests-\(UUID().uuidString)")
        layout = Layout(liveData: root.appendingPathComponent("Claude"), home: root.appendingPathComponent("swap-home"),
                        claudeApp: root.appendingPathComponent("Claude.app"), trash: root.appendingPathComponent("Trash"))
        try fm.createDirectory(at: layout.claudeApp, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.liveData, withIntermediateDirectories: true)
        try Login.writeJSON(["locale": "de-DE", "windowState": ["w": 1]], to: layout.liveData.appendingPathComponent("config.json"))
        claude = SimulatedClaude(liveData: layout.liveData)
        manager = AccountManager(layout: layout, claude: claude)
        manager.settleDelay = 0
        manager.log = { _ in }
        try Demo.signIn(layout.liveData, uuid: uuidA, marker: "A", days: 30)
        try claude.launchMain(app: layout.claudeApp)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    func place(_ name: String) throws -> Place {
        try XCTUnwrap(manager.snapshot().accounts.first { $0.account.name == name }).place
    }

    func liveTokens() throws -> String? {
        try Login.readJSON(layout.liveData.appendingPathComponent("config.json"))["oauth:tokenCacheV2"] as? String
    }

    /// Work (A) in the main Claude, Personal (B) saved.
    func twoAccounts() throws {
        try manager.rename("current", to: "Work")
        claude.signIn = { [uuidB] folder in try? Demo.signIn(folder, uuid: uuidB, marker: "B", days: 30) }
        try manager.addInMain()
        claude.signIn = nil
        try manager.switchTo("Work", nameForCurrent: "Personal")
    }

    func test_switchingKeepsEveryOtherSettingAndBacksUp() throws {
        try twoAccounts()
        XCTAssertEqual(try manager.snapshot().accounts.map(\.place), [.main, .saved])
        try manager.switchTo("Personal")
        XCTAssertEqual(Login.accountUUID(in: layout.liveData), uuidB)
        let config = try Login.readJSON(layout.liveData.appendingPathComponent("config.json"))
        XCTAssertEqual(config["locale"] as? String, "de-DE")
        XCTAssertEqual(config["windowState"] as? [String: Int], ["w": 1])
        XCTAssertNotNil(claude.mainPID(), "Claude was opened again")
        XCTAssertGreaterThanOrEqual(try fm.contentsOfDirectory(atPath: layout.backupsRoot.path).count, 3)
        XCTAssertEqual(try manager.switchTo(nil), "Switched Claude to “Work”.", "no name picks the next account")
    }

    func test_aWindowRunsOnTheAccountsOwnFolder() throws {
        try twoAccounts()
        let personal = try manager.find("Personal")
        let folder = layout.folder(of: personal)
        XCTAssertTrue(Files.exists(folder.appendingPathComponent("auth.json")))

        try manager.openWindow("Personal")
        XCTAssertNotNil(claude.pid(usingDataFolder: folder))
        XCTAssertEqual(try place("Personal"), .window)
        XCTAssertFalse(Files.exists(folder.appendingPathComponent("auth.json")), "its keys moved into config.json")
        let config = try Login.readJSON(folder.appendingPathComponent("config.json"))
        XCTAssertEqual(config["locale"] as? String, "de-DE", "a new window gets the main Claude's language")
        XCTAssertEqual(Login.accountUUID(in: folder), uuidB)

        // Nothing copies a sign-in a window runs on.
        XCTAssertThrowsError(try manager.switchTo("Personal")) { XCTAssertEqual($0 as? SwapError, .openInWindow("Personal")) }
        XCTAssertThrowsError(try manager.remove("Personal")) { XCTAssertEqual($0 as? SwapError, .openInWindow("Personal")) }
        XCTAssertThrowsError(try manager.switchTo(nil)) { XCTAssertEqual($0 as? SwapError, .noOtherAccount) }

        // The window refreshes its tokens; closing it and switching brings the newest ones.
        var rotated = try Login.readJSON(folder.appendingPathComponent("config.json"))
        rotated["oauth:tokenCacheV2"] = "rotated in the window"
        try Login.writeJSON(rotated, to: folder.appendingPathComponent("config.json"))
        try manager.switchTo("Personal", closeWindow: true)
        XCTAssertNil(claude.pid(usingDataFolder: folder))
        XCTAssertEqual(try liveTokens(), "rotated in the window")
        XCTAssertEqual(try place("Personal"), .main)
    }

    func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func test_sessionListsFollowTheAccountIntoItsWindowAndBack() throws {
        try twoAccounts()
        let personal = try manager.find("Personal")
        let folder = layout.folder(of: personal)
        let mainCode = layout.liveData.appendingPathComponent("claude-code-sessions/\(uuidB)/org")
        let ownCode = folder.appendingPathComponent("claude-code-sessions/\(uuidB)/org")
        let mainCowork = layout.liveData.appendingPathComponent("local-agent-mode-sessions/\(uuidB)/org")
        let ownCowork = folder.appendingPathComponent("local-agent-mode-sessions/\(uuidB)/org")
        try write("first session", to: mainCode.appendingPathComponent("local_1.json"))
        try write("main's tasks", to: mainCode.appendingPathComponent("scheduled-tasks.json"))
        try write("plugin", to: mainCowork.appendingPathComponent("rpm/manifest.json"))
        let workSession = layout.liveData.appendingPathComponent("claude-code-sessions/\(uuidA)/org/local_a.json")
        try write("work", to: workSession)
        // Left by a window opened before session lists moved: one copy differs, one is the same.
        try write("a fresh window's tasks", to: ownCode.appendingPathComponent("scheduled-tasks.json"))
        try write("plugin", to: ownCowork.appendingPathComponent("rpm/manifest.json"))

        try manager.openWindow("Personal")
        XCTAssertFalse(Files.exists(mainCode), "the list moved out of the main Claude")
        XCTAssertEqual(read(ownCode.appendingPathComponent("local_1.json")), "first session")
        XCTAssertEqual(read(ownCode.appendingPathComponent("scheduled-tasks.json")), "main's tasks", "the history wins")
        XCTAssertEqual(read(ownCowork.appendingPathComponent("rpm/manifest.json")), "plugin")
        let parked = try fm.subpathsOfDirectory(atPath: folder.appendingPathComponent("session-conflicts").path)
        XCTAssertEqual(parked.filter { $0.hasSuffix("scheduled-tasks.json") }.count, 1, "the differing copy is kept aside")
        XCTAssertFalse(parked.contains { $0.hasSuffix("manifest.json") }, "the identical copy is dropped")
        XCTAssertEqual(read(workSession), "work", "other accounts' lists stay put")

        // A refresh leaves an open window's list alone; the window adds a session.
        _ = try manager.snapshot()
        XCTAssertTrue(Files.exists(ownCode.appendingPathComponent("local_1.json")))
        try write("second session", to: ownCode.appendingPathComponent("local_2.json"))

        try manager.closeWindow("Personal")
        XCTAssertEqual(read(mainCode.appendingPathComponent("local_1.json")), "first session")
        XCTAssertEqual(read(mainCode.appendingPathComponent("local_2.json")), "second session")
        XCTAssertEqual(read(mainCowork.appendingPathComponent("rpm/manifest.json")), "plugin")
        XCTAssertFalse(Files.exists(ownCode))
        XCTAssertFalse(Files.exists(folder.appendingPathComponent(AccountManager.sessionsMarker)))

        // Quit from the window itself (⌘Q): the next look brings the list back.
        try manager.openWindow("Personal")
        try claude.quit(pid: try XCTUnwrap(claude.pid(usingDataFolder: folder)), timeout: 1)
        XCTAssertFalse(Files.exists(mainCode))
        _ = try manager.snapshot()
        XCTAssertEqual(read(mainCode.appendingPathComponent("local_2.json")), "second session")

        // Switching to it, and removing it, both leave its history in the main Claude.
        try manager.openWindow("Personal")
        try manager.switchTo("Personal", closeWindow: true)
        XCTAssertEqual(read(mainCode.appendingPathComponent("local_1.json")), "first session")
        try manager.switchTo("Work")
        try manager.openWindow("Personal")
        try claude.quit(pid: try XCTUnwrap(claude.pid(usingDataFolder: folder)), timeout: 1)
        try manager.remove("Personal")
        XCTAssertEqual(read(mainCode.appendingPathComponent("local_2.json")), "second session")
    }

    func test_theMainAccountOpensTheMainClaude() throws {
        try twoAccounts()
        XCTAssertEqual(try manager.openWindow("Work"), "“Work” is the account in the main Claude.")
        XCTAssertNil(claude.pid(usingDataFolder: layout.folder(of: try manager.find("Work"))))
    }

    func test_anAccountSignedInToInANewWindowJoinsTheList() throws {
        try manager.rename("current", to: "Work")
        claude.signIn = { [uuidC] folder in try? Demo.signIn(folder, uuid: uuidC, marker: "C", days: 30) }
        let folder = try manager.addInWindow(name: "Client")
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("new-"))

        let snapshot = try manager.snapshot()
        XCTAssertEqual(snapshot.newWindows, [])
        let client = try XCTUnwrap(snapshot.accounts.first { $0.account.uuid == uuidC })
        XCTAssertEqual(client.account.name, "Client")
        XCTAssertEqual(client.place, .window)
        XCTAssertEqual(client.folder.lastPathComponent, folder.lastPathComponent)
        XCTAssertNotNil(claude.mainPID(), "the main Claude kept running")

        try manager.closeWindow("Client")
        XCTAssertEqual(try place("Client"), .saved)
        try manager.switchTo("Client")
        XCTAssertEqual(Login.accountUUID(in: layout.liveData), uuidC)
        XCTAssertEqual(try place("Work"), .saved)
    }

    func test_aNewWindowThatNeverSignsInCanBeDiscarded() throws {
        _ = try manager.addInWindow(name: nil)
        let window = try XCTUnwrap(manager.snapshot().newWindows.first)
        XCTAssertNotNil(window.pid)
        XCTAssertThrowsError(try manager.discardNewWindow(window))
        try manager.closeNewWindow(window)
        try manager.discardNewWindow(window)
        XCTAssertEqual(try manager.snapshot().newWindows, [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.trash!.path).count, 1)
    }

    /// Leaves the note Claude writes in its data folder when it quits to install an update.
    func quitForUpdate(_ folder: URL, written: Date = Date(), _ extra: [String: Any] = [:]) throws {
        let note = ["ts": written.timeIntervalSince1970 * 1000, "windowVisible": true].merging(extra) { _, new in new }
        try Login.writeJSON(note, to: folder.appendingPathComponent(AccountManager.updateQuitNote))
        let pid = folder == layout.liveData ? claude.mainPID() : claude.pid(usingDataFolder: folder)
        try claude.quit(pid: XCTUnwrap(pid), timeout: 1)
    }

    func test_aWindowClaudeClosedToUpdateOpensAgain() throws {
        try twoAccounts()
        try manager.openWindow("Personal")
        let folder = layout.folder(of: try manager.find("Personal"))
        let note = folder.appendingPathComponent(AccountManager.updateQuitNote)

        // The main Claude keeps running, so the updater waits and the window comes back at once.
        claude.updaterIsRunning = true
        let written = Date()
        try quitForUpdate(folder, written: written)
        XCTAssertEqual(try place("Personal"), .saved)
        manager.reopenWindowsClosedByUpdates()
        XCTAssertEqual(try place("Personal"), .window)
        XCTAssertFalse(Files.exists(note), "Claude read its note")

        // Each quit is reopened once.
        try quitForUpdate(folder, written: written)
        manager.reopenWindowsClosedByUpdates()
        XCTAssertEqual(try place("Personal"), .saved)

        // Quitting by hand, Claude restarting itself and old notes are left alone.
        try manager.openWindow("Personal")
        try quitForUpdate(folder, ["userQuit": true, "navOnly": true])
        manager.reopenWindowsClosedByUpdates()
        try manager.openWindow("Personal")
        try quitForUpdate(folder, ["navOnly": true])
        manager.reopenWindowsClosedByUpdates()
        try manager.openWindow("Personal")
        try quitForUpdate(folder, written: Date(timeIntervalSinceNow: -400))
        manager.reopenWindowsClosedByUpdates()
        XCTAssertEqual(try place("Personal"), .saved)
    }

    func test_whileTheUpdateInstallsNothingStarts() throws {
        try twoAccounts()
        try manager.openWindow("Personal")
        let folder = layout.folder(of: try manager.find("Personal"))
        claude.updaterIsRunning = true
        try claude.quit(pid: XCTUnwrap(claude.mainPID()), timeout: 1)
        try quitForUpdate(folder)

        // Every copy has quit: the updater is replacing Claude.app.
        manager.reopenWindowsClosedByUpdates()
        XCTAssertFalse(claude.anyInstanceRunning())

        // It has, and opened the main Claude.
        claude.updaterIsRunning = false
        try claude.launchMain(app: layout.claudeApp)
        manager.reopenWindowsClosedByUpdates()
        XCTAssertEqual(try place("Personal"), .window)
    }

    func test_theMainClaudeClosedToUpdateOpensAgainWhileAWindowRuns() throws {
        try twoAccounts()
        try manager.openWindow("Personal")
        claude.updaterIsRunning = true
        try quitForUpdate(layout.liveData)
        manager.reopenWindowsClosedByUpdates()
        XCTAssertNotNil(claude.mainPID())
        XCTAssertEqual(try place("Work"), .main)
    }

    func test_theMainAccountSignedInTwiceBlocksSwitching() throws {
        try twoAccounts()
        let work = try manager.find("Work")
        // Someone signs in to Work again in a new window.
        claude.signIn = { [uuidA] folder in try? Demo.signIn(folder, uuid: uuidA, marker: "A2", days: 30) }
        try manager.addInWindow(name: nil)
        let status = try XCTUnwrap(manager.snapshot().accounts.first { $0.account.uuid == work.uuid })
        XCTAssertTrue(status.isSignedInTwice)
        XCTAssertNotEqual(status.folder, layout.folder(of: work), "the new sign-in replaced its folder")

        XCTAssertThrowsError(try manager.switchTo("Personal")) { XCTAssertEqual($0 as? SwapError, .signedInTwice("Work")) }
        XCTAssertThrowsError(try manager.addInMain()) { XCTAssertEqual($0 as? SwapError, .signedInTwice("Work")) }
        XCTAssertEqual(Login.accountUUID(in: layout.liveData), uuidA, "nothing changed")
        XCTAssertNotNil(claude.mainPID())
    }

    func test_aClaudeThatWontQuitIsLeftAlone() throws {
        try twoAccounts()
        claude.refusesToQuit = true
        XCTAssertThrowsError(try manager.switchTo("Personal")) { XCTAssertEqual($0 as? SwapError, .claudeDidNotQuit) }
        XCTAssertEqual(Login.accountUUID(in: layout.liveData), uuidA)
    }

    func test_removingMovesTheFolderToTheTrash() throws {
        try twoAccounts()
        XCTAssertThrowsError(try manager.remove("Work")) { XCTAssertEqual($0 as? SwapError, .isMain("Work")) }
        try manager.remove("Personal")
        XCTAssertEqual(manager.accounts().map(\.name), ["Work"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: layout.trash!.path).count, 1)
    }

    func test_namesAndLookups() throws {
        try twoAccounts()
        XCTAssertThrowsError(try manager.rename("Personal", to: "work")) { XCTAssertEqual($0 as? SwapError, .nameTaken("work")) }
        XCTAssertThrowsError(try manager.rename("Personal", to: "  ")) { XCTAssertEqual($0 as? SwapError, .emptyName) }
        try manager.rename("2", to: "Home")
        XCTAssertEqual(try manager.find("home").uuid, uuidB)
        XCTAssertEqual(try manager.find("bbbb").uuid, uuidB)
        XCTAssertThrowsError(try manager.find("nobody"))
    }

    func test_onlyOneChangeAtATime() throws {
        let held = try manager.withLock { try? manager.withLock { "inner" } }
        XCTAssertNil(held, "a second change waits for the first")
    }

    func test_expiredSignInsReadAsSignedOut() throws {
        let folder = root.appendingPathComponent("expired")
        try Demo.signIn(folder, uuid: uuidC, marker: "C", days: -1)
        XCTAssertNil(Login.expiry(in: folder))
        try Demo.signIn(folder, uuid: uuidC, marker: "C", days: 5)
        let expiry = try XCTUnwrap(Login.expiry(in: folder))
        XCTAssertEqual(expiry.timeIntervalSinceNow, 5 * 86_400, accuracy: 60)
    }

    func test_theFolderOfClaudeAccountSwapMovesOnceNoWindowRunsOnIt() throws {
        try twoAccounts()
        try manager.openWindow("Personal")
        try "[old] history\n".write(to: layout.home.appendingPathComponent("swap.log"), atomically: true, encoding: .utf8)
        var old = try XCTUnwrap(layout)
        let newHome = root.appendingPathComponent("multi-home")
        old.newHome = newHome
        let manager = AccountManager(layout: old, claude: claude)
        manager.settleDelay = 0

        _ = try manager.snapshot()
        XCTAssertFalse(Files.exists(newHome), "it stays while a window runs on a folder inside it")

        try manager.closeWindow("Personal")
        _ = try manager.snapshot()
        XCTAssertTrue(Files.isRealDirectory(newHome))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: old.home.path), newHome.path)
        XCTAssertEqual(try manager.snapshot().accounts.map(\.place), [.main, .saved], "the old path still leads to it")
        let log = try String(contentsOf: newHome.appendingPathComponent("activity.log"), encoding: .utf8)
        XCTAssertTrue(log.hasPrefix("[old] history\n"), "the old log's history comes first")
        XCTAssertTrue(log.contains("Closed"), "lines written before the move follow it")
        XCTAssertTrue(log.contains("is now Claude Multi-Accounts"))
        XCTAssertFalse(Files.exists(newHome.appendingPathComponent("swap.log")))

        // The next start uses the new folder.
        var moved = old
        moved.home = newHome
        moved.newHome = nil
        let fresh = AccountManager(layout: moved, claude: claude)
        fresh.settleDelay = 0
        fresh.log = { _ in }
        XCTAssertEqual(try fresh.switchTo("Personal"), "Switched Claude to “Personal”.")
        XCTAssertEqual(Login.accountUUID(in: layout.liveData), uuidB)
    }

    func test_aVersion2FolderIsUsedWhereItIsUntilItHasMoved() throws {
        let user = root.appendingPathComponent("user")
        let old = user.appendingPathComponent(".claude-desktop-swap")
        let new = user.appendingPathComponent(".claude-multi-accounts")
        XCTAssertEqual(Layout.homes(in: user).home.path, new.path)
        XCTAssertNil(Layout.homes(in: user).newHome)

        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertEqual(Layout.homes(in: user).home.path, old.path)
        XCTAssertEqual(Layout.homes(in: user).newHome?.path, new.path)

        try fm.moveItem(at: old, to: new)
        try fm.createSymbolicLink(at: old, withDestinationURL: new)
        XCTAssertEqual(Layout.homes(in: user).home.path, new.path, "the link left behind is not used")
        XCTAssertNil(Layout.homes(in: user).newHome)
    }
}

final class DemoTests: XCTestCase {
    func test_demoHasFourSyntheticAccountsInEveryState() throws {
        let manager = try Demo.makeManager()
        defer { try? FileManager.default.removeItem(at: Demo.root) }

        XCTAssertTrue(manager.layout.liveData.path.hasPrefix(Demo.root.path), "the demo never uses the real Claude")
        XCTAssertTrue(manager.layout.home.path.hasPrefix(Demo.root.path))
        let snapshot = try manager.snapshot()
        XCTAssertEqual(snapshot.accounts.map(\.account.name), ["Personal", "Work · Northwind", "Client · Acme Studio", "Research"])
        XCTAssertEqual(snapshot.accounts.map(\.place), [.main, .window, .saved, .saved])
        XCTAssertNotNil(snapshot.main.pid)
        XCTAssertNil(snapshot.accounts[3].loginExpires, "Research's sign-in has expired")
        XCTAssertEqual(manager.folderSize(of: snapshot.accounts[1]), 1_380_000_000)

        try manager.switchTo("Client · Acme Studio")
        XCTAssertEqual(try manager.snapshot().mainAccount?.account.name, "Client · Acme Studio")
    }
}
