# How Claude Multi-Accounts works

The rules the app and the `claude-multi-accounts` command follow, and the files they keep. Both are built on the same code, [`macos/Sources/MultiAccountsCore`](../macos/Sources/MultiAccountsCore).

## Claude's sign-in

The Claude desktop app keeps everything in its data folder, `~/Library/Application Support/Claude`. Its sign-in is two things in that folder:

| File | What | Read by this tool |
|------|------|------|
| `Cookies` (and `Cookies-journal`, `-wal`, `-shm`) | the claude.ai web session, cookies `sessionKey`, `sessionKeyV2`, `sessionKeyV3` on `claude.ai` | only names, hosts and expiry dates |
| `config.json` | `oauth:tokenCache`, `oauth:tokenCacheV2` (the tokens the Code tab runs on) and `lastKnownAccountUuid` (the account) | the account uuid; the tokens are copied unread |

The cookies and tokens are encrypted with one key from the Keychain item “Claude Safe Storage”. That key belongs to the app, not to an account or a data folder, so a sign-in copied to another folder on the same Mac still works there.

A data folder is **signed in** when its `Cookies` holds a claude.ai session cookie that hasn't expired (one without an expiry date lasts until Claude quits). Its **account** is `lastKnownAccountUuid`.

Everything else in the data folder (settings, extensions, connectors, Code sessions, which Claude already keeps per account under folders named after the account) is never touched by a switch.

## This tool's folder

```
~/.claude-multi-accounts/
    accounts.json        the accounts, in order
    accounts/<folder>/   each account's own folder
    backups/             the live sign-in before each change, the last 20
    runs/                outcomes handed from the detached worker to the command (see below)
    activity.log         one line per step
    .lock                held while anything changes, so the app and the command never change things at once
```

`accounts.json`:

```json
{
  "version" : 1,
  "accounts" : [
    { "uuid" : "4f0c…", "name" : "Work", "savedAt" : "2026-10-21T09:30:00" },
    { "uuid" : "9b2e…", "name" : "Client", "savedAt" : "2026-10-21T10:02:11", "folder" : "new-20261021-100118" }
  ]
}
```

- `uuid` is Claude's account id; `name` is free text, unique ignoring case.
- `folder` is the account's folder under `accounts/`. It is left out when it is the uuid; an account first signed in to in a new window keeps the folder that window was started on.
- `savedAt` is local time, when its sign-in was last saved.

Up to version 2 the app was called Claude Account Swap and kept this folder at `~/.claude-desktop-swap`. While that folder exists and the new one doesn't, it is used where it is. Whenever the list is read and no Claude window runs on a folder inside it, it moves (rename, same disk) to `~/.claude-multi-accounts`, a link to the new place is left at the old path (so a process that started before the move, or an older copy of the tool, still finds everything), and `swap.log` becomes `activity.log`, followed by any lines logged since. The link is never used to choose the folder.

An account folder holds the account's sign-in in one of two shapes:

- **Saved only** (never opened side by side): the cookie files and `auth.json`, which holds the three `config.json` keys.
- **A data folder** (opened side by side at least once): a full Claude data folder whose `config.json` holds the keys, next to the cookie files and everything that window's Claude keeps.

A folder's sign-in is read from `config.json` when it exists, otherwise from `auth.json`.

## Which Claude is which

Claude holds no single-instance lock on macOS: `open -n` starts a second copy, and without `--user-data-dir` both would share one data folder. So:

- the **main Claude** is the running `Claude.app/Contents/MacOS/Claude` started without `--user-data-dir`;
- a **window** of an account is the running copy whose `--user-data-dir` names that account's folder.

Command lines are read with `sysctl(KERN_PROCARGS2)`, paths compared with `realpath(3)`. A copy is asked to quit with `NSRunningApplication.terminate()` for its pid (AppleScript's `tell application` would pick any copy), falling back to SIGTERM, which Electron handles as a normal quit. Nothing is ever force-quit.

Started from a relocated data folder, Claude turns off its local pairing with the Claude in Chrome extension for that copy. It ignores the `CLAUDE_USER_DATA_DIR` variable in signed builds, which is why the switch is used.

## Where each account is

1. **Main**: the main Claude's data folder is signed in, to this account.
2. **Window**: a copy of Claude runs on its folder.
3. **Saved**: its folder holds a sign-in.
4. **Not saved**: none of the above; it is saved the first time the main Claude switches away from it.

An account that is both main and has a window running on its folder is **signed in twice** (it was signed in to again in a new window). Switching is refused until that window closes.

## Opening an account side by side

1. If it is the main account, bring the main Claude forward. If its window runs, bring that forward.
2. Refuse if its folder holds no sign-in.
3. If the folder is saved only, turn it into a data folder: write a `config.json` holding the keys from `auth.json` plus the main Claude's `locale` and `userThemeMode`, then remove `auth.json`.
4. Start `open -n -a Claude.app --args --user-data-dir=<folder>`, with this tool's own environment variables left out (Claude hands its environment to every terminal in its Code tab).

The window refreshes the account's tokens in that folder, so the folder always holds the newest sign-in. Closing the window leaves everything there.

**The account's session lists come along.** Claude keeps the Code tab's and Cowork's session lists per account, in `claude-code-sessions/<account>/` and `local-agent-mode-sessions/<account>/` inside its data folder (each session's transcript is under `~/.claude`, which every copy of Claude shares). It skips session folders reached through a symbolic link, so they are moved instead:

- Before the window starts, the account's two folders move (rename, same disk) from the main Claude's data folder into the account's folder, and the marker `.swap-sessions-here` is written there. The lock is held until the window's process shows, so nothing moves them back while it starts.
- Once no window runs on the folder (closed from the app, or with ⌘Q in the window), they move back. That happens on the next look at the list, and always before the account's sign-in goes into the main Claude or its folder goes to the Trash. It waits while the main Claude is running signed in to that same account.
- If both places hold a folder for the account (one was made by a window opened before this behaviour existed), they are merged: files only one side has are moved in; where both have a file, the copy from the place holding the history wins (the account's folder while the marker is there, otherwise the main Claude's). An identical other copy is deleted and a different one is moved to `session-conflicts/<time>/` in the account's folder. Nothing else is deleted.

**Adding an account in a new window** starts a copy on a new folder `accounts/new-<time>/` holding a `config.json` with the main Claude's language and theme and a marker `.swap-new-window.json` (`{"name": …}` when a name was given). Whenever the list is read, a marked folder that is signed in joins it (Claude writes its cookies to disk in batches, so this happens within about 30 seconds of signing in): as a new account using that folder, or, for an account already in the list, as its new folder (its earlier folder goes to the Trash, unless a window still runs on it). The marker is then removed. A marked folder whose window closed before signing in can be opened again or moved to the Trash.

## When Claude updates

Once an update has downloaded, a Claude window that sits unfocused and idle for 10 minutes, with no Code session running, quits to install it. Before quitting it writes the note `stealth-relaunch` in its data folder: `{"ts": <ms since 1970>, "windowVisible": …, "navEntries": …}`, the page to show again. Claude reads the note and deletes it when it starts, and ignores one older than 5 minutes. Quitting by hand or a plain restart writes the same note marked `userQuit` or `navOnly`.

Claude's updater (Squirrel's `ShipIt`, running from `Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt`) then waits until every copy of Claude has quit. Then it replaces `Claude.app` and opens it again, without `--user-data-dir`: that is the main Claude. So on its own:

- an account's window that quit for an update never comes back;
- a main Claude that quit for an update stays away while any account's window runs;
- while a window keeps running, the update doesn't install, and Claude logs "Previous update install did not apply" when the copy that quit starts again.

Every 3 seconds the app looks for a note younger than 5 minutes, without `userQuit` or `navOnly`, in Claude's data folder and in each account's folder that no copy runs on. It reopens that copy with `open -g`, which leaves the app in front where it is, and it acts on each note once. While the updater runs and no copy of Claude does, it is replacing `Claude.app`, so the app waits until the updater has opened the main Claude. Then it reopens the account windows. **Settings → Claude updates** turns this off.

## Switching the main Claude to an account

1. If it is already the main account, open Claude or bring it forward. Done.
2. Refuse if its folder holds no sign-in, if the main account is signed in twice, or if the account's window is open (unless asked to close it, which quits that window first).
3. Quit the main Claude and wait up to 90 seconds; then wait 1.5 seconds for its helpers to finish writing. If it doesn't quit, stop: nothing has changed, and Claude is opened again if it was running.
4. Copy the live sign-in to `backups/`.
5. Save the live sign-in into the folder of the account it belongs to, adding that account to the list if it is new. A signed-out Claude, or one that hasn't recorded its account yet, saves nothing (the backup has it).
6. Refuse if Claude has started again meanwhile (after an update, say).
7. Put the account's sign-in in the main data folder: remove every cookie file first (a leftover journal from another account would be replayed into the copied database), copy its cookie files, and replace the three keys in `config.json`, keeping every other key. Prove the new `config.json` parses, since Claude wipes one it can't read.
8. Open Claude.

**Adding an account in the main Claude** is the same with nothing put in place at step 7: the three keys and the cookie files are removed, so Claude opens signed out.

## Safety rules

- **One place per sign-in.** A sign-in is copied only from a folder no Claude runs on, and never into one. That is what keeps Claude's rotating tokens from being split between two copies, which would sign the account out.
- **Nothing changes while the Claude using it runs**, and Claude is never force-quit.
- **Back up before every change** to the main sign-in, keeping the last 20.
- **Never log out.** Claude's own Log out ends the sign-in on Anthropic's side, which is what this tool avoids. Nothing is sent to Anthropic.
- **Removing goes to the Trash.** Removing an account moves its folder to the Trash; the main account and an account with an open window can't be removed.
- **Stop when unsure.** Anything unexpected stops the change with a message saying why.

## The detached worker

Quitting Claude ends everything it started, including a terminal in its Code tab, so the command can't do a switch itself when it runs there. `switch` and `add` hand the work to a process started in a new session through a middle step that exits at once, so launchd adopts it:

```
claude-multi-accounts switch Work                      the command, waiting
└─ claude-multi-accounts __detach <result> switch Work   starts the worker and exits
   claude-multi-accounts __work <result> switch Work     does the switch, writes runs/<id>.json
```

The command prints the worker's outcome when the result appears. The worker is marked by its arguments, never by the environment: Claude, reopened by the worker, would pass an environment variable on to its Code tab's terminals.

## The demo

`ClaudeMultiAccounts --demo` (and `--render-screenshots <folder>`, which draws the README screenshots) runs all of this on four synthetic accounts in a temporary folder, with a pretend Claude that starts nothing. The demo never reads or writes the real Claude data, and removing an account there moves it into that temporary folder.

The command's end-to-end tests use a pretend Claude made of files instead (`CMA_FAKE_APP`, with `CMA_CLAUDE_DIR`, `CMA_HOME` and `CMA_TRASH` pointing at temporary folders); see [`FakeClaude.swift`](../macos/Sources/MultiAccountsCore/FakeClaude.swift).
