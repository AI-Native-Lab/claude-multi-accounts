# Claude Multi-Accounts for Windows (beta)

Several Claude accounts at once in the Claude desktop app for Windows: each account opens in its own Claude
window, already signed in, next to the main Claude. The same rules and the same `accounts.json` format as the
[macOS app](../macos), ported to C# / WinForms.

## Install

1. Download `ClaudeMultiAccounts-<version>-windows-x64.zip` from the releases and unzip it anywhere (for example
   `%LOCALAPPDATA%\Programs\ClaudeMultiAccounts`).
2. Run `ClaudeMultiAccounts.exe`. It is one file with .NET included; Windows 10 or 11, 64-bit.
   SmartScreen may warn the first time because the file isn't signed: **More info → Run anyway**.

Needs Claude for Windows (from claude.ai/download, the Microsoft Store/MSIX build or the older installer).

## Use

- **Add Account → Sign In in a New Window**: a new Claude window opens at its sign-in screen; the main Claude
  keeps running. Sign in there and the account joins the list within about 30 seconds.
- **Open Side by Side**: opens a saved account in its own Claude window, with its own Code and Cowork session
  lists. **Close Window** quits that window; its sign-in stays saved.
- **Switch**: puts an account in the main Claude instead. Claude quits and reopens signed in to it.
- The notification-area icon (next to the clock) lists every account: one click opens it side by side.
- Never use Claude's own **Log out**: it ends that sign-in on Anthropic's side, so its saved copy stops working.

## How it differs from the Mac

The rules are those of [docs/how-it-works.md](../docs/how-it-works.md). What is different on Windows:

| | macOS | Windows |
|---|---|---|
| Claude's data folder | `~/Library/Application Support/Claude` | MSIX build: `%LOCALAPPDATA%\Packages\Claude_…\LocalCache\Roaming\Claude` (what Claude calls `%APPDATA%\Claude`); older installer: `%APPDATA%\Claude` |
| Cookies | `Cookies` | `Network\Cookies` |
| Encryption key | Keychain item "Claude Safe Storage", one per Mac | `os_crypt.encrypted_key` in the data folder's own `Local State`, protected by DPAPI for the Windows user |
| Starting a copy | `open -n -a Claude --args --user-data-dir=…` | `claude-desktop.exe --user-data-dir=…` (the MSIX execution alias), or `AnthropicClaude\claude.exe` |
| Quitting a copy | `NSRunningApplication.terminate()` | `WM_QUERYENDSESSION` + `WM_ENDSESSION` (`ENDSESSION_CLOSEAPP`) to its window; Claude logs "Windows session ending (close-app) - quitting the app" and quits normally. Closing the window only hides Claude in the tray, so it isn't used. |
| Bringing a copy forward | `NSRunningApplication.activate` | Starting Claude again on the same folder; the running copy shows its window |
| Removing | Trash | Recycle Bin |
| This tool's folder | `~/.claude-multi-accounts` | `%USERPROFILE%\.claude-multi-accounts` |

**The key.** On the Mac one key opens every data folder. On Windows each data folder would make its own key, and
a sign-in copied into a folder with another key can't be read. So every account folder gets a copy of the main
Claude's `Local State` before Claude ever starts on it, and a switch is refused (before anything quits) if an
account's key differs from the main Claude's. A saved-only account folder holds `Network\Cookies`, `auth.json`
and `Local State`.

While Claude runs it holds its cookie database without sharing it, so the expiry date of a running copy's
sign-in can't be read; it then shows as "signed in" from its config keys alone.

Not ported yet: the `claude-multi-accounts` command line tool and the `--demo` mode.

## Build

```powershell
windows\scripts\build.ps1        # runs the tests, then writes windows\dist\ClaudeMultiAccounts.exe and a zip
dotnet run --project windows\CoreTests              # the account rules against a pretend Claude
dotnet run --project windows\CoreTests -- --real    # starts, finds, brings forward and quits a throwaway Claude window
```

Needs the .NET 8 SDK. `windows\scripts\make-icon.ps1` makes `AppIcon.ico` from `assets/icon/AppIcon-1024.png`.
