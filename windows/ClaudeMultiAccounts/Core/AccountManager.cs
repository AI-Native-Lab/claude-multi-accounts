using System.Globalization;
using System.Text.Json.Nodes;

namespace ClaudeMultiAccounts.Core;

/// <summary>Where an account's sign-in is now.</summary>
public enum Place
{
    /// <summary>Signed in to the main Claude.</summary>
    Main,
    /// <summary>Open in its own Claude window, next to the main one.</summary>
    Window,
    /// <summary>Kept in its folder, ready to switch to or to open in its own window.</summary>
    Saved,
    /// <summary>Known, but its sign-in is saved only when the main Claude switches away from it.</summary>
    NotSaved,
}

public sealed record AccountStatus(Account Account, int Number, Place Place, int? WindowPid, Expiry LoginExpires,
                                   bool HasSavedSignIn, string Folder)
{
    public bool IsSignedInTwice => Place == Place.Main && WindowPid != null;
}

public sealed record MainState(int? Pid, bool SignedIn, string? Uuid, Expiry LoginExpires)
{
    public bool Running => Pid != null;
}

/// <summary>A Claude window opened to sign in to an account that isn't in the list yet.</summary>
public sealed record NewWindow(string Folder, string? Name, int? Pid);

public sealed record Snapshot(MainState Main, List<AccountStatus> Accounts, List<NewWindow> NewWindows)
{
    public AccountStatus? MainAccount => Accounts.FirstOrDefault(a => a.Place == Place.Main);
    /// <summary>Signed in to an account this tool hasn't named yet.</summary>
    public bool MainIsUnnamed => Main.SignedIn && Main.Uuid != null && MainAccount == null;
}

/// <summary>
/// Saves, switches and opens Claude accounts. A port of the macOS app's AccountManager.
///
/// Rules that keep every sign-in working:
/// - Each sign-in lives in exactly one place: the main Claude, its account's folder, or the Claude window
///   running on that folder. Copies are only ever made of a sign-in nothing runs on.
/// - Nothing is changed while the Claude that uses it runs, and nothing is ever force-quit.
/// - The live sign-in is backed up before each change, and nothing is sent to Anthropic. Claude's own
///   "Log out" ends the sign-in on the server, which is exactly what this avoids.
/// </summary>
public sealed partial class AccountManager
{
    public Layout Layout { get; }
    public TimeSpan QuitTimeout { get; set; } = TimeSpan.FromSeconds(90);
    /// <summary>Time for Claude's helper processes to finish writing after it quits.</summary>
    public TimeSpan SettleDelay { get; set; } = TimeSpan.FromSeconds(1.5);
    /// <summary>How long a new window may take to show up as a running process.</summary>
    public TimeSpan LaunchTimeout { get; set; } = TimeSpan.FromSeconds(20);
    public Action<string> Log { get; set; }

    readonly IClaudeControl claude;
    const int KeepBackups = 20;
    public const string NewWindowMarker = ".swap-new-window.json";

    public AccountManager(Layout layout, IClaudeControl? claude = null)
    {
        Layout = layout;
        this.claude = claude ?? new SystemClaudeControl(layout);
        Log = message => AppendLog(message, layout.LogFile);
    }

    // MARK: Reading

    public List<Account> Accounts()
    {
        try { return Registry.Load(Layout.AccountsFile); } catch { return new(); }
    }

    public MainState MainState()
    {
        string config = Path.Combine(Layout.LiveData, "config.json");
        if (!File.Exists(config))
            throw new SwapException($"Claude's data isn't at {config}. Open Claude for Windows once, then try again.");
        int? pid = claude.MainPid();
        var keys = Login.Keys(Layout.LiveData);
        var expiry = keys == null ? Expiry.None : Login.ExpiryIn(Layout.LiveData);
        bool signedIn = keys != null && expiry.Valid;
        return new MainState(pid, signedIn, signedIn ? Login.AccountUuid(Layout.LiveData) : null, signedIn ? expiry : Expiry.None);
    }

    /// <summary>Everything at once: the main Claude, every account and any windows still signing in.</summary>
    public Snapshot Snapshot()
    {
        TryWithLock(() =>
        {
            AdoptNewWindows();
            ReturnSessionsFromClosedWindows();
        });
        var main = MainState();
        var statuses = Accounts().Select((a, i) => StatusOf(a, i + 1, main)).ToList();
        return new Snapshot(main, statuses, NewWindows());
    }

    public Account Find(string query) => Accounts().Find(query);

    AccountStatus StatusOf(Account account, int number, MainState main)
    {
        string folder = Layout.FolderOf(account);
        bool saved = Login.HasSignIn(folder);
        int? window = claude.PidUsing(folder);
        Place place;
        Expiry expiry;
        if (main.SignedIn && main.Uuid == account.Uuid)
        {
            place = Place.Main;
            expiry = main.LoginExpires;
        }
        else
        {
            place = window != null ? Place.Window : saved ? Place.Saved : Place.NotSaved;
            expiry = saved ? Login.ExpiryIn(folder) : Expiry.None;
        }
        return new AccountStatus(account, number, place, window, expiry, saved, folder);
    }

    List<NewWindow> NewWindows()
    {
        if (!Directory.Exists(Layout.AccountsRoot)) return new();
        return Directory.EnumerateDirectories(Layout.AccountsRoot)
            .Where(f => File.Exists(Path.Combine(f, NewWindowMarker)))
            .OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal)
            .Select(f =>
            {
                string? name = null;
                try { name = Login.ReadJson(Path.Combine(f, NewWindowMarker))["name"]?.GetValue<string>(); } catch { }
                return new NewWindow(f, name, claude.PidUsing(f));
            })
            .ToList();
    }

    // MARK: Switching the main Claude

    /// <summary>Puts an account's sign-in in the main Claude: quits Claude, saves the sign-in it had under its
    /// account, puts the target's in its place and opens Claude again. With <paramref name="closeWindow"/>,
    /// a target open in its own window is closed first.</summary>
    public string SwitchTo(string? query, string? nameForCurrent = null, bool closeWindow = false, Action<string>? progress = null)
    {
        progress ??= _ => { };
        return WithLock(() =>
        {
            AdoptNewWindows();
            var accounts = Accounts();
            var main = MainState();
            var target = query != null ? accounts.Find(query) : NextAccount(accounts, main);
            if (main.SignedIn && main.Uuid == target.Uuid)
            {
                OpenMain();
                return $"Already signed in as “{target.Name}”.";
            }
            string source = Layout.FolderOf(target);
            if (!Login.HasSignIn(source))
                throw new SwapException($"“{target.Name}” isn't saved yet: its sign-in is saved the first time the main Claude switches away from it.");
            RefuseIfSignedInTwice(accounts, main);
            RequireClaude();
            // Found out before anything quits: a sign-in only works where the same key opens it.
            if (Login.EncryptionKey(source) is string key && Login.EncryptionKey(Layout.LiveData) is string liveKey && key != liveKey)
                throw new SwapException($"The sign-in of “{target.Name}” is locked with a different key than this Claude uses, so it can't be moved into it. Open it side by side instead, or sign in to it again. Nothing was changed.");

            if (claude.PidUsing(source) is int pid)
            {
                if (!closeWindow) throw new SwapException($"“{target.Name}” is open in its own window. Close that window first.");
                progress($"Closing the window of “{target.Name}”…");
                Log($"Closing the window of “{target.Name}”");
                claude.Quit(pid, QuitTimeout);
                Settle();
            }
            ReopeningOnFailure(() =>
            {
                QuitMain(progress);
                BackUpLive("before-switch");
                SaveLive(accounts, nameForCurrent);
            });
            progress($"Signing Claude in to “{target.Name}”…");
            EnsureMainQuit();
            ReturnSessions(target);
            try { Login.Copy(source, Layout.LiveData); }
            catch
            {
                // Login.Copy checks before it changes anything, so Claude opens as it was.
                try { LaunchMain(); } catch { }
                throw;
            }
            LaunchMain();
            Log($"Switched to “{target.Name}”");
            return $"Switched Claude to “{target.Name}”.";
        });
    }

    /// <summary>Saves the main Claude's account and reopens Claude signed out, to sign in to another account.</summary>
    public string AddInMain(string? nameForCurrent = null, Action<string>? progress = null)
    {
        progress ??= _ => { };
        return WithLock(() =>
        {
            AdoptNewWindows();
            var accounts = Accounts();
            RefuseIfSignedInTwice(accounts, MainState());
            RequireClaude();
            Account? saved = null;
            ReopeningOnFailure(() =>
            {
                QuitMain(progress);
                BackUpLive("before-add");
                saved = SaveLive(accounts, nameForCurrent);
            });
            EnsureMainQuit();
            Login.Copy(null, Layout.LiveData);
            LaunchMain();
            string kept = saved != null ? $"“{saved.Name}” is saved. " : "";
            return kept + "Claude reopened signed out: sign in with your other account. It's saved automatically the next time you switch.";
        });
    }

    /// <summary>Opens the main Claude, or brings it to the front.</summary>
    public void OpenMain()
    {
        if (claude.MainPid() is int pid) claude.Activate(pid);
        else { RequireClaude(); LaunchMain(); }
    }

    // MARK: Side by side

    /// <summary>Opens a saved account in its own Claude window, next to the main Claude.</summary>
    public string OpenWindow(string query) => WithLock(() => OpenWindowHoldingLock(query, inBackground: false));

    string OpenWindowHoldingLock(string query, bool inBackground)
    {
        AdoptNewWindows();
        var account = Find(query);
        var main = MainState();
        if (main.SignedIn && main.Uuid == account.Uuid)
        {
            OpenMain();
            return $"“{account.Name}” is the account in the main Claude.";
        }
        string folder = Layout.FolderOf(account);
        if (claude.PidUsing(folder) is int pid)
        {
            claude.Activate(pid);
            return $"Brought the window of “{account.Name}” to the front.";
        }
        if (!Login.HasSignIn(folder))
            throw new SwapException($"“{account.Name}” isn't saved yet: its sign-in is saved the first time the main Claude switches away from it.");
        RequireClaude();
        Login.PrepareForWindow(folder, Layout.LiveData);
        TakeSessions(account);
        try { claude.LaunchSide(folder, inBackground); }
        catch { try { ReturnSessions(account); } catch { } throw; }
        // Keep the lock until the window's process shows, or a refresh in between would take it for
        // closed and move its sessions back.
        var deadline = DateTime.UtcNow + LaunchTimeout;
        while (claude.PidUsing(folder) == null && DateTime.UtcNow < deadline) Thread.Sleep(200);
        Log($"Opened “{account.Name}” in its own window");
        return $"Opened “{account.Name}” in its own Claude window.";
    }

    /// <summary>Quits an account's own Claude window. Its sign-in stays in its folder.</summary>
    public string CloseWindow(string query)
    {
        var account = Find(query);
        if (claude.PidUsing(Layout.FolderOf(account)) is not int pid) return $"“{account.Name}” has no window open.";
        claude.Quit(pid, QuitTimeout);
        Log($"Closed the window of “{account.Name}”");
        Settle();
        TryWithLock(ReturnSessionsFromClosedWindows);
        return $"Closed the window of “{account.Name}”.";
    }

    /// <summary>Opens a Claude window on a new, empty folder, to sign in to another account while the main
    /// Claude keeps running. The account joins the list, named <paramref name="name"/>, once it has signed in.</summary>
    public string AddInWindow(string? name)
    {
        return WithLock(() =>
        {
            string? clean = name != null ? ValidName(name, Accounts(), null) : null;
            RequireClaude();
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            string folder = Path.Combine(Layout.AccountsRoot, $"new-{stamp}");
            for (int n = 2; Files.Exists(folder); n++) folder = Path.Combine(Layout.AccountsRoot, $"new-{stamp}-{n}");
            Login.PrepareForWindow(folder, Layout.LiveData);
            var marker = new JsonObject();
            if (clean != null) marker["name"] = clean;
            Login.WriteJson(marker, Path.Combine(folder, NewWindowMarker));
            claude.LaunchSide(folder);
            Log($"Opened a new window to sign in to {(clean != null ? $"“{clean}”" : "another account")}");
            return folder;
        });
    }

    public void OpenNewWindow(NewWindow window)
    {
        if (claude.PidUsing(window.Folder) is int pid) claude.Activate(pid);
        else { RequireClaude(); claude.LaunchSide(window.Folder); }
    }

    public void CloseNewWindow(NewWindow window)
    {
        if (claude.PidUsing(window.Folder) is int pid) claude.Quit(pid, QuitTimeout);
    }

    /// <summary>Moves the folder of a window that never finished signing in to the Recycle Bin.</summary>
    public void DiscardNewWindow(NewWindow window)
    {
        WithLock(() =>
        {
            if (!File.Exists(Path.Combine(window.Folder, NewWindowMarker))) return 0;
            if (claude.PidUsing(window.Folder) != null) throw new SwapException("That window is still open. Close it first.");
            MoveToTrash(window.Folder);
            Log($"Discarded the new-account folder {Path.GetFileName(window.Folder)}");
            return 0;
        });
    }

    public void Activate(int pid) => claude.Activate(pid);

    // MARK: The list

    /// <summary>Renames an account. "current" names the account in the main Claude, adding it to the list.</summary>
    public void Rename(string query, string name)
    {
        WithLock(() =>
        {
            var accounts = Accounts();
            int index;
            if (query == "current")
            {
                var main = MainState();
                if (!main.SignedIn || main.Uuid == null) throw new SwapException("Claude isn't signed in.");
                index = accounts.FindIndex(a => a.Uuid == main.Uuid);
                if (index < 0)
                {
                    accounts.Add(new Account { Uuid = main.Uuid, Name = ValidName(name, accounts, null) });
                    index = accounts.Count - 1;
                }
            }
            else
            {
                var account = accounts.Find(query);
                index = accounts.FindIndex(a => a.Uuid == account.Uuid);
            }
            accounts[index].Name = ValidName(name, accounts, accounts[index].Uuid);
            SaveAccounts(accounts);
            return 0;
        });
    }

    /// <summary>Forgets an account: its folder goes to the Recycle Bin. The account itself is untouched.</summary>
    public string Remove(string query)
    {
        return WithLock(() =>
        {
            var accounts = Accounts();
            var account = accounts.Find(query);
            var main = MainState();
            if (main.SignedIn && main.Uuid == account.Uuid)
                throw new SwapException($"“{account.Name}” is the account in the main Claude. Switch to another account first.");
            string folder = Layout.FolderOf(account);
            if (claude.PidUsing(folder) != null) throw new SwapException($"“{account.Name}” is open in its own window. Close that window first.");
            ReturnSessions(account);
            if (Files.Exists(folder)) MoveToTrash(folder);
            SaveAccounts(accounts.Where(a => a.Uuid != account.Uuid).ToList());
            Log($"Removed “{account.Name}”");
            return $"Removed “{account.Name}”. The account itself is untouched; sign in to it again to add it back.";
        });
    }

    // MARK: Helpers

    /// <summary>Accounts signed in to in a new window join the list as soon as Claude records which account
    /// it is. Expects the lock to be held.</summary>
    void AdoptNewWindows()
    {
        var accounts = Accounts();
        MainState? main = null;
        try { main = MainState(); } catch { }
        bool changed = false;
        foreach (var window in NewWindows())
        {
            if (!Login.ExpiryIn(window.Folder).Valid || Login.AccountUuid(window.Folder) is not string uuid) continue;
            string folderName = Path.GetFileName(window.Folder);
            int index = accounts.FindIndex(a => a.Uuid == uuid);
            if (index >= 0)
            {
                // Signed in again to an account already in the list: the new sign-in replaces its old folder.
                string old = Layout.FolderOf(accounts[index]);
                if (claude.PidUsing(old) != null) continue;
                if (!(main?.SignedIn == true && main.Uuid == uuid)) { try { ReturnSessions(accounts[index]); } catch { } }
                accounts[index].Folder = folderName;
                accounts[index].SavedAt = Registry.Now();
                if (Files.Exists(old)) { try { MoveToTrash(old); } catch { } }
                Log($"“{accounts[index].Name}” was signed in to again in a new window; its earlier folder went to the Recycle Bin");
            }
            else
            {
                string name = UniqueName(window.Name ?? accounts.DefaultName(), accounts);
                accounts.Add(new Account { Uuid = uuid, Name = name, SavedAt = Registry.Now(), Folder = folderName });
                Log($"New account “{name}” ({uuid}), signed in to in its own window");
            }
            try { File.Delete(Path.Combine(window.Folder, NewWindowMarker)); } catch { }
            changed = true;
        }
        if (changed) { try { SaveAccounts(accounts); } catch { } }
    }

    /// <summary>The saved account after the one in the main Claude, so switching without a name rotates.</summary>
    Account NextAccount(List<Account> accounts, MainState main)
    {
        var ready = accounts.Where(a => a.Uuid != main.Uuid && Login.HasSignIn(Layout.FolderOf(a))
                                        && claude.PidUsing(Layout.FolderOf(a)) == null).ToList();
        if (ready.Count == 0) throw new SwapException("There's no other saved account to switch to.");
        int start = accounts.FindIndex(a => a.Uuid == main.Uuid);
        if (start < 0) return ready[0];
        var ordered = accounts.Skip(start + 1).Concat(accounts.Take(start));
        return ordered.FirstOrDefault(c => ready.Any(r => r.Uuid == c.Uuid)) ?? ready[0];
    }

    /// <summary>The main Claude's account must not also be open in its own window: saving its sign-in would
    /// write over the folder that window runs on.</summary>
    void RefuseIfSignedInTwice(List<Account> accounts, MainState main)
    {
        if (!main.SignedIn || accounts.FirstOrDefault(a => a.Uuid == main.Uuid) is not Account account) return;
        if (claude.PidUsing(Layout.FolderOf(account)) != null)
            throw new SwapException($"“{account.Name}” is signed in both in the main Claude and in its own window. Close that window first.");
    }

    /// <summary>Saves the main Claude's sign-in under its account. Returns that account, or null.</summary>
    Account? SaveLive(List<Account> accounts, string? nameForCurrent)
    {
        var main = MainState();
        if (!main.SignedIn) { Log("Claude is signed out; nothing to save"); return null; }
        if (main.Uuid is not string uuid)
        {
            Log("Claude is signed in but hasn't recorded which account yet; kept a backup only.");
            return null;
        }
        int index = accounts.FindIndex(a => a.Uuid == uuid);
        if (index < 0)
        {
            string name = UniqueName(string.IsNullOrWhiteSpace(nameForCurrent) ? accounts.DefaultName() : nameForCurrent, accounts);
            accounts.Add(new Account { Uuid = uuid, Name = name });
            index = accounts.Count - 1;
            Log($"New account “{name}” ({uuid})");
        }
        string folder = Layout.FolderOf(accounts[index]);
        if (claude.PidUsing(folder) != null)
            throw new SwapException($"“{accounts[index].Name}” is signed in both in the main Claude and in its own window. Close that window first.");
        Directory.CreateDirectory(Layout.AccountsRoot);
        Login.Copy(Layout.LiveData, folder);
        accounts[index].SavedAt = Registry.Now();
        SaveAccounts(accounts);
        Log($"Saved the sign-in of “{accounts[index].Name}”");
        return accounts[index];
    }

    /// <summary>Copies the main Claude's sign-in to backups\, keeping the last 20.</summary>
    void BackUpLive(string reason)
    {
        if (!Login.HasSignIn(Layout.LiveData)) return;
        try
        {
            Directory.CreateDirectory(Layout.BackupsRoot);
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss-fff", CultureInfo.InvariantCulture);
            Login.Copy(Layout.LiveData, Path.Combine(Layout.BackupsRoot, $"{stamp}-{reason}"));
            var old = Directory.EnumerateDirectories(Layout.BackupsRoot).Select(Path.GetFileName)
                .Where(n => !n!.StartsWith('.')).OrderBy(n => n, StringComparer.Ordinal).ToList();
            foreach (var name in old.Take(Math.Max(0, old.Count - KeepBackups)))
                try { Directory.Delete(Path.Combine(Layout.BackupsRoot, name!), true); } catch { }
        }
        catch (Exception e) { Log($"Couldn't back up the live sign-in: {e.Message}"); }
    }

    void QuitMain(Action<string> progress)
    {
        if (claude.MainPid() is not int pid) return;
        progress("Quitting Claude…");
        Log("Quitting Claude");
        claude.Quit(pid, QuitTimeout);
        Settle();
    }

    /// <summary>Claude may restart itself (after an update, say); its files are never changed while it runs.</summary>
    void EnsureMainQuit()
    {
        if (claude.MainPid() != null) throw new SwapException("Claude started again in the meantime. Nothing was changed; try again.");
    }

    /// <summary>Runs the steps before the live sign-in changes; if one fails, Claude is opened again as it was.</summary>
    void ReopeningOnFailure(Action steps)
    {
        bool wasRunning = claude.MainPid() != null;
        try { steps(); }
        catch
        {
            if (wasRunning && claude.MainPid() == null) { try { LaunchMain(); } catch { } }
            throw;
        }
    }

    void LaunchMain()
    {
        Log("Opening Claude");
        claude.LaunchMain();
    }

    void Settle()
    {
        if (SettleDelay > TimeSpan.Zero) Thread.Sleep(SettleDelay);
    }

    void RequireClaude()
    {
        if (!claude.Installed) throw new SwapException("Claude for Windows isn't installed. Install it from claude.ai/download.");
    }

    static string ValidName(string name, List<Account> accounts, string? ignoring)
    {
        string clean = name.Trim();
        if (clean.Length == 0) throw new SwapException("The name can't be empty.");
        if (accounts.Any(a => a.Uuid != ignoring && string.Equals(a.Name, clean, StringComparison.OrdinalIgnoreCase)))
            throw new SwapException($"There's already an account named “{clean}”.");
        return clean;
    }

    static string UniqueName(string name, List<Account> accounts)
    {
        string baseName = name.Trim();
        string candidate = baseName.Length == 0 ? accounts.DefaultName() : baseName;
        for (int n = 2; accounts.Any(a => string.Equals(a.Name, candidate, StringComparison.OrdinalIgnoreCase)); n++)
            candidate = $"{baseName} {n}";
        return candidate;
    }

    void SaveAccounts(List<Account> accounts)
    {
        Directory.CreateDirectory(Layout.Home);
        Registry.Save(accounts, Layout.AccountsFile);
    }

    void MoveToTrash(string folder)
    {
        if (Layout.Trash != null)
        {
            Directory.CreateDirectory(Layout.Trash);
            Directory.Move(folder, Path.Combine(Layout.Trash, $"{Path.GetFileName(folder)}-{Guid.NewGuid().ToString()[..8]}"));
        }
        else
        {
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(folder,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
    }

    /// <summary>Runs <paramref name="body"/> holding the lock file, so two copies never change things at once.</summary>
    T WithLock<T>(Func<T> body)
    {
        Directory.CreateDirectory(Layout.Home);
        FileStream handle;
        try { handle = new FileStream(Layout.LockFile, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new SwapException("Another change to the accounts is in progress. Try again in a moment."); }
        using (handle) return body();
    }

    void TryWithLock(Action body)
    {
        try { WithLock(() => { body(); return 0; }); } catch { }
    }

    static readonly object LogGate = new();

    public static void AppendLog(string message, string path)
    {
        try
        {
            lock (LogGate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.AppendAllText(path, $"[{Registry.Now()}] {message}\n");
            }
        }
        catch { }
    }
}
