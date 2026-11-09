using System.Globalization;

namespace ClaudeMultiAccounts.Core;

/// <summary>
/// An account's Code and Cowork session lists follow it into its own window.
///
/// Claude keeps them per account inside its data folder, at &lt;tree&gt;\&lt;account uuid&gt;\ for each tree
/// below. While an account's window runs, its session folders are moved (renamed, on the same disk) from
/// the main Claude's data folder into the account's folder, and moved back once the window has closed.
/// A marker file in the account's folder says its session folders came from the main Claude.
/// </summary>
public sealed partial class AccountManager
{
    static readonly string[] SessionTrees = { "claude-code-sessions", "local-agent-mode-sessions" };
    const string SessionsMarker = ".swap-sessions-here";

    /// <summary>Moves an account's session folders from the main Claude into its own folder, before its
    /// window opens. Expects the lock, and neither Claude to be using them.</summary>
    void TakeSessions(Account account)
    {
        string folder = Layout.FolderOf(account);
        foreach (var tree in SessionTrees)
        {
            string main = Path.Combine(Layout.LiveData, tree, account.Uuid);
            string own = Path.Combine(folder, tree, account.Uuid);
            if (!Files.IsRealFolder(main)) continue;
            // Left by a window opened before session lists moved with it.
            if (Files.IsRealFolder(own)) Absorb(own, main, ConflictsFolder(folder, tree, account.Uuid));
            Directory.CreateDirectory(Path.GetDirectoryName(own)!);
            Move(main, own);
        }
        File.WriteAllBytes(Path.Combine(folder, SessionsMarker), Array.Empty<byte>());
        Log($"Moved the session list of “{account.Name}” into its window's folder");
    }

    /// <summary>Moves an account's session folders back to the main Claude once its window has closed.
    /// Expects the lock.</summary>
    void ReturnSessions(Account account)
    {
        string folder = Layout.FolderOf(account);
        string marker = Path.Combine(folder, SessionsMarker);
        bool ownIsHistory = File.Exists(marker);
        bool moved = false;
        foreach (var tree in SessionTrees)
        {
            string main = Path.Combine(Layout.LiveData, tree, account.Uuid);
            string own = Path.Combine(folder, tree, account.Uuid);
            if (!Files.IsRealFolder(own)) continue;
            if (!Files.IsRealFolder(main))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(main)!);
                Move(own, main);
            }
            else if (ownIsHistory)
            {
                Absorb(main, own, ConflictsFolder(folder, tree, account.Uuid));
                Move(own, main);
            }
            else
            {
                Absorb(own, main, ConflictsFolder(folder, tree, account.Uuid));
            }
            moved = true;
        }
        try { File.Delete(marker); } catch { }
        if (moved) Log($"Moved the session list of “{account.Name}” back to the main Claude");
    }

    /// <summary>Returns the session folders of every account whose window has closed, unless the main Claude
    /// is running signed in to that account. Expects the lock.</summary>
    void ReturnSessionsFromClosedWindows()
    {
        MainState main;
        try { main = MainState(); } catch { return; }
        foreach (var account in Accounts())
        {
            string folder = Layout.FolderOf(account);
            if (!SessionTrees.Any(t => Files.IsRealFolder(Path.Combine(folder, t, account.Uuid)))) continue;
            if (claude.PidUsing(folder) != null) continue;
            if (main.Running && main.SignedIn && main.Uuid == account.Uuid) continue;
            try { ReturnSessions(account); }
            catch (Exception e) { Log($"Couldn't move the session list of “{account.Name}” back: {e.Message}"); }
        }
    }

    static string ConflictsFolder(string folder, string tree, string uuid) =>
        Path.Combine(folder, "session-conflicts", DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture), tree, uuid);

    /// <summary>Moves everything in <paramref name="stray"/> that <paramref name="history"/> lacks into it, then
    /// removes <paramref name="stray"/>. Where both have a file, history's stays: an identical stray copy is
    /// deleted, a different one goes to <paramref name="conflicts"/>.</summary>
    internal static void Absorb(string stray, string history, string conflicts)
    {
        foreach (var from in Directory.EnumerateFileSystemEntries(stray).ToList())
        {
            string name = Path.GetFileName(from);
            string to = Path.Combine(history, name);
            bool fromIsFolder = Files.IsRealFolder(from), toIsFolder = Files.IsRealFolder(to);
            if (!Files.Exists(to))
            {
                Move(from, to);
            }
            else if (fromIsFolder && toIsFolder)
            {
                Absorb(from, to, Path.Combine(conflicts, name));
            }
            else if (!fromIsFolder && !toIsFolder && SameContents(from, to))
            {
                File.Delete(from);
            }
            else
            {
                Directory.CreateDirectory(conflicts);
                Move(from, Path.Combine(conflicts, name));
            }
        }
        Directory.Delete(stray, recursive: false);
    }

    /// <summary>Renames, refusing to replace anything or to copy across disks, so a move can't half happen.</summary>
    internal static void Move(string from, string to)
    {
        if (Files.Exists(to)) throw new SwapException($"Couldn't move {from} to {to}: something is already there.");
        if (!string.Equals(Path.GetPathRoot(Path.GetFullPath(from)), Path.GetPathRoot(Path.GetFullPath(to)), StringComparison.OrdinalIgnoreCase))
            throw new SwapException($"Couldn't move {from} to {to}: they are on different disks.");
        if (Directory.Exists(from)) Directory.Move(from, to);
        else File.Move(from, to, overwrite: false);
    }

    static bool SameContents(string a, string b)
    {
        var fa = new FileInfo(a);
        var fb = new FileInfo(b);
        if (fa.Length != fb.Length) return false;
        using var sa = fa.OpenRead();
        using var sb = fb.OpenRead();
        var ba = new byte[81920];
        var bb = new byte[81920];
        while (true)
        {
            int na = sa.Read(ba, 0, ba.Length);
            int nb = sb.ReadAtLeast(bb, na, throwOnEndOfStream: false);
            if (na != nb) return false;
            if (na == 0) return true;
            if (!ba.AsSpan(0, na).SequenceEqual(bb.AsSpan(0, nb))) return false;
        }
    }
}
