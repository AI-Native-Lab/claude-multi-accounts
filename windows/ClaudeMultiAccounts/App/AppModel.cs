using System.Diagnostics;
using ClaudeMultiAccounts.Core;

namespace ClaudeMultiAccounts.App;

/// <summary>The state the window and the tray menu show, and every action they offer. Anything that reads or
/// changes accounts runs on one background queue, one thing at a time; the UI hears about it on its thread.</summary>
sealed class AppModel
{
    public Snapshot? Snapshot { get; private set; }
    public string? Problem { get; private set; }
    public string? Busy { get; private set; }
    public Dictionary<string, long> Sizes { get; private set; } = new();
    public event Action? Changed;

    public readonly AccountManager Manager;
    public readonly AppSettings Settings;
    readonly SynchronizationContext ui;
    readonly TaskFactory work = new(new ConcurrentExclusiveSchedulerPair().ExclusiveScheduler);
    bool refreshing;

    public AppModel(AccountManager manager, AppSettings settings)
    {
        Manager = manager;
        Settings = settings;
        ui = SynchronizationContext.Current as WindowsFormsSynchronizationContext
             ?? throw new InvalidOperationException("AppModel must be made on the UI thread, after WinForms is set up.");
    }

    public List<AccountStatus> Statuses => Snapshot?.Accounts ?? new();
    public string? MainName => Snapshot?.MainAccount?.Account.Name;

    public string Headline
    {
        get
        {
            if (Snapshot == null) return Problem == null ? "Claude Multi-Accounts" : "Claude isn't set up yet";
            if (!Snapshot.Main.SignedIn) return "Claude is signed out";
            return $"Claude: {MainName ?? "an unnamed account"}";
        }
    }

    public string Subheadline
    {
        get
        {
            if (Snapshot == null) return Problem ?? "";
            var parts = new List<string> { Snapshot.Main.Running ? "Running" : "Not open" };
            if (Snapshot.Main.SignedIn && Describe(Snapshot.Main.LoginExpires) is { Length: > 0 } d) parts.Add($"signed in {d}");
            else if (Snapshot.Main.SignedIn) parts.Add("signed in");
            int windows = Statuses.Count(s => s.Place == Place.Window);
            if (windows > 0) parts.Add(windows == 1 ? "1 account side by side" : $"{windows} accounts side by side");
            return string.Join(" · ", parts);
        }
    }

    public static string Describe(Expiry expiry) => expiry.Kind switch
    {
        ExpiryKind.None => "sign-in expired",
        ExpiryKind.UntilQuit => "until Claude quits",
        ExpiryKind.Until => "until " + expiry.Date!.Value.ToString("d MMM"),
        _ => "",
    };

    void Post(Action action) => ui.Post(_ => { action(); Changed?.Invoke(); }, null);

    public void Refresh()
    {
        if (refreshing) return;
        refreshing = true;
        bool reopen = Settings.ReopenAfterUpdates;
        work.StartNew(() =>
        {
            if (reopen) { try { Manager.ReopenWindowsClosedByUpdates(); } catch { } }
            Snapshot? snapshot = null;
            string? problem = null;
            try { snapshot = Manager.Snapshot(); }
            catch (Exception e) { problem = e.Message; }
            Post(() => { Snapshot = snapshot; Problem = problem; refreshing = false; });
        });
    }

    /// <summary>Reads everything at once and waits for it; used before drawing screenshots.</summary>
    public void RefreshNow()
    {
        try { Snapshot = Manager.Snapshot(); Problem = null; }
        catch (Exception e) { Snapshot = null; Problem = e.Message; }
        foreach (var status in Snapshot?.Accounts ?? new())
            if (Directory.Exists(status.Folder)) Sizes[status.Account.Uuid] = Files.FolderSize(status.Folder);
        Changed?.Invoke();
    }

    public void RefreshSizes()
    {
        Task.Run(() =>
        {
            var sizes = new Dictionary<string, long>();
            foreach (var status in Snapshot?.Accounts ?? new())
                if (Directory.Exists(status.Folder)) sizes[status.Account.Uuid] = Files.FolderSize(status.Folder);
            Post(() => Sizes = sizes);
        });
    }

    // MARK: Actions

    public void SwitchTo(AccountStatus status)
    {
        if (status.Place == Place.Main) { OpenMain(); return; }
        if (NameForMainAccount() is not string nameForCurrent) return;
        string name = status.Account.Name;
        bool closeWindow = false;
        if (status.Place == Place.Window)
        {
            if (!Prompt.Confirm($"Switch the main Claude to “{name}”?",
                    $"“{name}” is open in its own window. That window closes first, so its sign-in is only in one place. Then Claude quits and reopens signed in to “{name}”; Code sessions that are running stop.",
                    "Close Window and Switch")) return;
            closeWindow = true;
        }
        else if (Settings.AskBeforeSwitching)
        {
            bool dontAsk = false;
            if (!Prompt.Confirm($"Switch Claude to “{name}”?",
                    $"Claude quits and reopens signed in to “{name}” a few seconds later. Code sessions that are running stop; you can reopen them afterwards.",
                    "Switch", suppressible: true, ref dontAsk)) return;
            if (dontAsk) { Settings.AskBeforeSwitching = false; Settings.Save(); }
        }
        Perform($"Switching to {name}…", progress =>
            Manager.SwitchTo(status.Account.Uuid, nameForCurrent, closeWindow, progress));
    }

    public void OpenWindow(AccountStatus status) =>
        Perform($"Opening {status.Account.Name}…", _ => Manager.OpenWindow(status.Account.Uuid));

    public void CloseWindow(AccountStatus status) =>
        Perform($"Closing {status.Account.Name}…", _ => Manager.CloseWindow(status.Account.Uuid));

    public void ShowWindow(AccountStatus status)
    {
        if (status.WindowPid is int pid) Perform(null, _ => Manager.Activate(pid));
    }

    public void AddInWindow()
    {
        if (Prompt.Text("Sign in to another account",
                "A new Claude window opens at its sign-in screen; the main Claude keeps running. Sign in there, and the account joins this list.\n\nName for the account (optional; your email works well):",
                "For example: Work", "Open Window", allowEmpty: true) is not string name) return;
        Perform("Opening a new window…", _ => Manager.AddInWindow(name.Length == 0 ? null : name));
    }

    public void AddInMain()
    {
        if (!Prompt.Confirm("Sign in to another account in the main Claude?",
                $"Claude quits and reopens signed out, so you can sign in with another account. {(MainName != null ? $"“{MainName}” stays saved. " : "")}Code sessions that are running stop.\n\nTip: never use Claude's own Log out. It ends that sign-in for good, so its saved copy stops working.",
                "Continue")) return;
        if (NameForMainAccount() is not string nameForCurrent) return;
        Perform("Reopening Claude signed out…", progress => Manager.AddInMain(nameForCurrent, progress));
    }

    public void NameMainAccount()
    {
        if (Prompt.Text("Name this account",
                "Claude is signed in to an account this app hasn't seen yet. Give it a name (your email works well):",
                "For example: Personal") is not string name) return;
        Perform(null, _ => Manager.Rename("current", name));
    }

    public void Rename(AccountStatus status)
    {
        if (Prompt.Text($"Rename “{status.Account.Name}”", "New name:", status.Account.Name, initial: status.Account.Name) is not string name) return;
        Perform(null, _ => Manager.Rename(status.Account.Uuid, name));
    }

    public void Remove(AccountStatus status)
    {
        if (!Prompt.Confirm($"Remove “{status.Account.Name}”?",
                "Its folder, with its saved sign-in and its own window's data, goes to the Recycle Bin, where you can still get it back. The account itself is not touched; to use it here again, sign in to it again.",
                "Move to Recycle Bin")) return;
        Perform(null, _ => Manager.Remove(status.Account.Uuid));
    }

    public void OpenMain() => Perform(null, _ => Manager.OpenMain());
    public void OpenNewWindow(NewWindow window) => Perform(null, _ => Manager.OpenNewWindow(window));
    public void CloseNewWindow(NewWindow window) => Perform("Closing the window…", _ => Manager.CloseNewWindow(window));
    public void DiscardNewWindow(NewWindow window) => Perform(null, _ => Manager.DiscardNewWindow(window));

    public void ShowFolder(AccountStatus status) => Reveal(status.Folder);

    public void ShowAccountsFolder()
    {
        Directory.CreateDirectory(Manager.Layout.AccountsRoot);
        Reveal(Manager.Layout.AccountsRoot);
    }

    public void ShowClaudeDataFolder() => Reveal(Manager.Layout.LiveData);

    public void OpenLog()
    {
        if (File.Exists(Manager.Layout.LogFile))
            Process.Start(new ProcessStartInfo(Manager.Layout.LogFile) { UseShellExecute = true });
        else
            Prompt.Info("No activity yet", "The log starts with the first change to an account.");
    }

    static void Reveal(string path)
    {
        if (Directory.Exists(path)) Process.Start("explorer.exe", $"\"{path}\"");
    }

    /// <summary>When the main Claude holds an account this app hasn't named, asks for a name. Returns "" to use a
    /// default name, or null when cancelled.</summary>
    string? NameForMainAccount()
    {
        if (Snapshot?.MainIsUnnamed != true) return "";
        return Prompt.Text("Name the account Claude is signed in to now",
            "It is saved under this name when Claude switches away from it (your email works well). Leave it empty for a default name.",
            "For example: Personal", "Continue", allowEmpty: true);
    }

    void Perform(string? label, Action<Action<string>> action)
    {
        if (Busy != null) return;
        Busy = label ?? "Working…";
        Changed?.Invoke();
        work.StartNew(() =>
        {
            Exception? failure = null;
            try { action(message => Post(() => Busy = message)); }
            catch (Exception e) { failure = e; }
            Post(() =>
            {
                Busy = null;
                Refresh();
                RefreshSizes();
                if (failure != null) Prompt.Error(failure);
            });
        });
    }
}
