namespace ClaudeMultiAccounts.Core;

/// <summary>
/// Claude windows closed by Claude's own updates come back.
///
/// Once an update has downloaded, a Claude window that sits unfocused and idle quits to install it,
/// leaving the note <c>stealth-relaunch</c> in its data folder. Claude reads that note, and deletes it,
/// when it starts again. The updater only ever opens the main Claude again: it knows nothing of the
/// other copies' data folders. So an account's window that quit this way would never come back.
/// </summary>
public sealed partial class AccountManager
{
    const string UpdateQuitNote = "stealth-relaunch";
    static readonly TimeSpan UpdateQuitNoteLifetime = TimeSpan.FromMinutes(5);
    /// <summary>The update notes acted on already, so each quit is reopened only once.</summary>
    readonly HashSet<string> handledUpdateQuits = new();

    /// <summary>Opens again the main Claude and every account's window that quit to install an update in the
    /// last five minutes, once per quit. Account windows wait until the main Claude is back, so nothing
    /// starts from a Claude that is being replaced.</summary>
    public void ReopenWindowsClosedByUpdates()
    {
        var now = DateTimeOffset.UtcNow;
        var folders = new[] { Layout.LiveData }.Concat(Accounts().Select(Layout.FolderOf));
        if (!folders.Any(f => UnhandledUpdateQuit(f, now) != null)) return;
        TryWithLock(() =>
        {
            if (claude.MainPid() == null)
            {
                if (UnhandledUpdateQuit(Layout.LiveData, now) is string note)
                {
                    handledUpdateQuits.Add(note);
                    Log("Claude quit to install an update; opening it again");
                    try { claude.LaunchMain(inBackground: true); }
                    catch (Exception e) { Log($"Couldn't open Claude again: {e.Message}"); }
                }
                // The account windows come back once the updated main Claude runs.
                return;
            }
            MainState? main = null;
            try { main = MainState(); } catch { }
            foreach (var account in Accounts())
            {
                if (main?.SignedIn == true && main.Uuid == account.Uuid) continue;
                string folder = Layout.FolderOf(account);
                if (claude.PidUsing(folder) != null || UnhandledUpdateQuit(folder, now) is not string note) continue;
                handledUpdateQuits.Add(note);
                Log($"Claude closed the window of “{account.Name}” to install an update; opening it again");
                try { OpenWindowHoldingLock(account.Uuid, inBackground: true); }
                catch (Exception e) { Log($"Couldn't open the window of “{account.Name}” again: {e.Message}"); }
            }
        });
    }

    /// <summary>The note in a data folder saying Claude quit there to install an update, as a key to remember it
    /// by, when written in the last five minutes and not acted on yet. Quitting by hand, or Claude restarting
    /// itself, marks the note userQuit or navOnly, and those are left alone.</summary>
    string? UnhandledUpdateQuit(string dataFolder, DateTimeOffset now)
    {
        string path = Path.Combine(dataFolder, UpdateQuitNote);
        if (!File.Exists(path)) return null;
        try
        {
            var note = Login.ReadJson(path);
            double written = note["ts"]!.GetValue<double>();
            if (note["userQuit"]?.GetValue<bool>() == true || note["navOnly"]?.GetValue<bool>() == true) return null;
            string key = $"{dataFolder} {written}";
            var age = now - DateTimeOffset.FromUnixTimeMilliseconds((long)written);
            if (age < TimeSpan.Zero || age >= UpdateQuitNoteLifetime || handledUpdateQuits.Contains(key)) return null;
            return key;
        }
        catch { return null; }
    }
}
