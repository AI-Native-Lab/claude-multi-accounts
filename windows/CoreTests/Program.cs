// End-to-end checks of the account rules against a pretend Claude made of files, in a temporary folder.
// Run: dotnet run --project windows\CoreTests
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using ClaudeMultiAccounts.Core;

if (args.Contains("--real")) return RealClaude.Run();

int failures = 0, passed = 0;
void Check(bool ok, string what)
{
    if (ok) { passed++; Console.WriteLine($"  ok   {what}"); }
    else { failures++; Console.WriteLine($"  FAIL {what}"); }
}
void Throws(Action action, string contains, string what)
{
    try { action(); Check(false, what + " (didn't refuse)"); }
    catch (SwapException e) { Check(e.Message.Contains(contains, StringComparison.OrdinalIgnoreCase), $"{what}: {e.Message}"); }
}

string root = Path.Combine(Path.GetTempPath(), "cma-tests-" + Guid.NewGuid().ToString("N")[..8]);
string live = Path.Combine(root, "Claude");
var layout = new Layout
{
    Home = Path.Combine(root, "home"), LiveData = live, Launcher = "fake", Trash = Path.Combine(root, "trash"),
};
var fake = new FakeClaude(layout);
var manager = new AccountManager(layout, fake) { SettleDelay = TimeSpan.Zero, LaunchTimeout = TimeSpan.FromMilliseconds(50) };

const string uuidA = "aaaaaaaa-1111-4111-8111-111111111111";
const string uuidB = "bbbbbbbb-2222-4222-8222-222222222222";
const string uuidC = "cccccccc-3333-4333-8333-333333333333";

// Claude signed in to A, with settings and A's session lists.
Directory.CreateDirectory(live);
Fake.WriteLocalState(live, "KEY-1");
Fake.SignIn(live, uuidA, "tokA");
var config = Login.ReadJson(Path.Combine(live, "config.json"));
config["locale"] = "vi-VN"; config["userThemeMode"] = "dark"; config["somethingElse"] = 42;
Login.WriteJson(config, Path.Combine(live, "config.json"));
Directory.CreateDirectory(Path.Combine(live, "claude-code-sessions", uuidA, "s1"));
File.WriteAllText(Path.Combine(live, "claude-code-sessions", uuidA, "s1", "meta.json"), "A1");
fake.MainRunning = true;

try
{
    Console.WriteLine("Reading");
    var snap = manager.Snapshot();
    Check(snap.Main.SignedIn && snap.Main.Uuid == uuidA, "main is signed in to A");
    Check(snap.Main.LoginExpires.Kind == ExpiryKind.Until, $"cookie expiry read ({snap.Main.LoginExpires.Describe()})");
    Check(snap.MainIsUnnamed, "A isn't named yet");
    manager.Rename("current", "Personal");
    Check(manager.Snapshot().MainAccount?.Account.Name == "Personal", "naming the main account adds it");

    Console.WriteLine("Adding an account in the main Claude");
    manager.AddInMain();
    string folderA = Path.Combine(layout.AccountsRoot, uuidA);
    Check(fake.Quits == 1 && fake.MainRunning, "Claude quit once and reopened");
    Check(Login.AccountUuid(folderA) == uuidA && File.Exists(Path.Combine(folderA, "auth.json")), "A saved as auth.json");
    Check(File.Exists(Path.Combine(folderA, @"Network\Cookies")), "A's cookies saved");
    Check(Login.EncryptionKey(folderA) == "KEY-1", "A's folder has the main key (Local State)");
    Check(!Login.HasSignIn(live) && !File.Exists(Path.Combine(live, @"Network\Cookies")), "main is signed out");
    Check(Login.ReadJson(Path.Combine(live, "config.json"))["somethingElse"]?.GetValue<int>() == 42, "other config keys kept");
    Check(Directory.GetDirectories(layout.BackupsRoot).Length == 1, "a backup was made");

    // The user signs in to B in the main Claude.
    Fake.SignIn(live, uuidB, "tokB");
    snap = manager.Snapshot();
    Check(snap.MainIsUnnamed && snap.Accounts.Single().Place == Place.Saved, "B in main, A saved");

    Console.WriteLine("Switching");
    manager.SwitchTo("Personal", nameForCurrent: "Work");
    Check(Login.AccountUuid(live) == uuidA, "main is A again");
    Check(Login.Keys(live)!["oauth:tokenCache"]!.GetValue<string>() == "tokA", "A's tokens are back");
    Check(Login.AccountUuid(Path.Combine(layout.AccountsRoot, uuidB)) == uuidB, "B saved under its folder");
    Check(manager.Accounts().Select(a => a.Name).SequenceEqual(new[] { "Personal", "Work" }), "list: Personal, Work");
    Check(Login.ReadJson(Path.Combine(live, "config.json"))["locale"]?.GetValue<string>() == "vi-VN", "settings untouched by switching");
    Check(manager.SwitchTo("Personal").StartsWith("Already"), "switching to the main account just opens it");

    Console.WriteLine("Side by side");
    Directory.CreateDirectory(Path.Combine(live, "local-agent-mode-sessions", uuidB, "x"));
    File.WriteAllText(Path.Combine(live, "local-agent-mode-sessions", uuidB, "x", "t.json"), "B");
    manager.OpenWindow("Work");
    string folderB = Path.Combine(layout.AccountsRoot, uuidB);
    Check(fake.Windows.Contains(Layout.Normalize(folderB)), "B's window runs on its folder");
    Check(File.Exists(Path.Combine(folderB, "config.json")) && !File.Exists(Path.Combine(folderB, "auth.json")), "B's folder became a data folder");
    var bConfig = Login.ReadJson(Path.Combine(folderB, "config.json"));
    Check(bConfig["locale"]?.GetValue<string>() == "vi-VN" && bConfig["lastKnownAccountUuid"]?.GetValue<string>() == uuidB, "language copied, B's keys in config.json");
    Check(File.Exists(Path.Combine(folderB, "local-agent-mode-sessions", uuidB, "x", "t.json"))
          && !Directory.Exists(Path.Combine(live, "local-agent-mode-sessions", uuidB)), "B's sessions moved into its folder");
    snap = manager.Snapshot();
    Check(snap.Accounts.First(a => a.Account.Name == "Work").Place == Place.Window, "B shows as its own window");
    Check(Directory.Exists(Path.Combine(folderB, "local-agent-mode-sessions", uuidB)), "a refresh leaves an open window's sessions alone");
    Throws(() => manager.SwitchTo("Work"), "own window", "switching to an open window is refused");
    Throws(() => manager.Remove("Work"), "own window", "removing an open window is refused");

    // The window adds a session, then closes.
    File.WriteAllText(Path.Combine(folderB, "local-agent-mode-sessions", uuidB, "x", "new.json"), "B2");
    manager.CloseWindow("Work");
    Check(!fake.Windows.Contains(Layout.Normalize(folderB)), "B's window closed");
    Check(File.Exists(Path.Combine(live, "local-agent-mode-sessions", uuidB, "x", "new.json")), "B's sessions came back, new one included");
    Check(!File.Exists(Path.Combine(folderB, ".swap-sessions-here")), "marker removed");

    Console.WriteLine("Switching to an account that has a data folder");
    manager.SwitchTo("Work");
    Check(Login.AccountUuid(live) == uuidB, "main is B");
    Check(Login.AccountUuid(folderA) == uuidA, "A saved again");

    Console.WriteLine("A sign-in locked with another key is refused");
    Fake.WriteLocalState(folderA, "KEY-OTHER");
    Throws(() => manager.SwitchTo("Personal"), "different key", "switch refused");
    Check(Login.AccountUuid(live) == uuidB && fake.MainRunning, "nothing changed, Claude running again");
    Fake.WriteLocalState(folderA, "KEY-1");

    Console.WriteLine("Adding an account in a new window");
    string newFolder = manager.AddInWindow("Client");
    Check(fake.Windows.Contains(Layout.Normalize(newFolder)) && Login.EncryptionKey(newFolder) == "KEY-1", "new window started with the main key");
    snap = manager.Snapshot();
    Check(snap.NewWindows.Single().Name == "Client", "it shows as signing in");
    Fake.SignIn(newFolder, uuidC, "tokC");   // the user signs in there
    snap = manager.Snapshot();
    var client = snap.Accounts.FirstOrDefault(a => a.Account.Name == "Client");
    Check(client != null && client.Place == Place.Window && client.Account.Folder == Path.GetFileName(newFolder), "C joined the list with its window's folder");
    Check(snap.NewWindows.Count == 0, "no window left signing in");
    Throws(() => manager.Rename("Client", "personal"), "already", "duplicate names refused");

    Console.WriteLine("Removing");
    manager.CloseWindow("Client");
    manager.Remove("Client");
    Check(!manager.Accounts().Any(a => a.Name == "Client") && !Directory.Exists(newFolder), "C removed");
    Check(Directory.GetDirectories(layout.Trash!).Length == 1, "its folder went to the trash");
    Throws(() => manager.Remove("Work"), "main Claude", "removing the main account is refused");

    Console.WriteLine("Claude that won't quit");
    fake.RefuseQuit = true;
    Throws(() => manager.SwitchTo("Personal"), "didn't quit", "switch stops");
    Check(Login.AccountUuid(live) == uuidB, "main sign-in untouched");
    fake.RefuseQuit = false;

    Console.WriteLine("Cookie database held open by a running Claude");
    using (new FileStream(Path.Combine(live, @"Network\Cookies"), FileMode.Open, FileAccess.ReadWrite, FileShare.None))
    {
        var main = manager.MainState();
        Check(main.SignedIn && main.LoginExpires.Kind == ExpiryKind.Unknown, "still signed in, expiry unknown");
    }

    Console.WriteLine("Accounts file stays compatible with the Mac app");
    var json = JsonNode.Parse(File.ReadAllText(layout.AccountsFile))!;
    Check(json["version"]!.GetValue<int>() == 1 && json["accounts"]![0]!["uuid"] != null && json["accounts"]![0]!["folder"] == null, "version 1, folder left out when it is the uuid");
}
catch (Exception e)
{
    failures++;
    Console.WriteLine($"  CRASH {e}");
}
finally
{
    try { Directory.Delete(root, true); } catch { }
}

Console.WriteLine($"\n{passed} passed, {failures} failed");
return failures == 0 ? 0 : 1;

/// <summary>A pretend Claude: running copies are a flag and a set of folders; quitting is immediate.</summary>
sealed class FakeClaude : IClaudeControl
{
    readonly Layout layout;
    public bool MainRunning;
    public bool RefuseQuit;
    public int Quits;
    public readonly HashSet<string> Windows = new();
    readonly Dictionary<int, string> pids = new();
    int next = 100;

    public FakeClaude(Layout layout) { this.layout = layout; }
    public bool Installed => true;
    public int? MainPid() => MainRunning ? 1 : null;
    public int? PidUsing(string folder)
    {
        string f = Layout.Normalize(folder);
        if (f == Layout.Normalize(layout.LiveData)) return MainPid();
        foreach (var (pid, path) in pids) if (path == f) return pid;
        return null;
    }
    public bool AnyInstanceRunning() => MainRunning || Windows.Count > 0;
    public void Quit(int pid, TimeSpan timeout)
    {
        if (RefuseQuit) throw new SwapException("Claude didn't quit within 90 seconds.");
        Quits++;
        if (pid == 1) MainRunning = false;
        else if (pids.Remove(pid, out var f)) Windows.Remove(f);
    }
    public void LaunchMain(bool inBackground = false) => MainRunning = true;
    public void LaunchSide(string dataFolder, bool inBackground = false)
    {
        string f = Layout.Normalize(dataFolder);
        Windows.Add(f);
        pids[next++] = f;
    }
    public void Activate(int pid) { }
}

static class Fake
{
    public static void WriteLocalState(string folder, string key)
    {
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "Local State"), $"{{\"os_crypt\":{{\"encrypted_key\":\"{key}\"}}}}");
    }

    /// <summary>What Claude leaves after signing in: the keys in config.json and a session cookie.</summary>
    public static void SignIn(string folder, string uuid, string token)
    {
        string configPath = Path.Combine(folder, "config.json");
        var config = File.Exists(configPath) ? Login.ReadJson(configPath) : new JsonObject();
        config["oauth:tokenCache"] = token;
        config["oauth:tokenCacheV2"] = token + "-v2";
        config["lastKnownAccountUuid"] = uuid;
        Login.WriteJson(config, configPath);
        Directory.CreateDirectory(Path.Combine(folder, "Network"));
        string db = Path.Combine(folder, "Network", "Cookies");
        File.Delete(db);
        long expires = (DateTime.UtcNow.AddDays(30).ToFileTimeUtc()) / 10;
        Sql.Exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, has_expires INTEGER);"
                     + $"INSERT INTO cookies VALUES ('.claude.ai','sessionKey','',X'763130AABB',{expires},1);");
    }
}

static class Sql
{
    [DllImport("winsqlite3.dll")] static extern int sqlite3_open([MarshalAs(UnmanagedType.LPUTF8Str)] string f, out IntPtr db);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, IntPtr cb, IntPtr arg, IntPtr err);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_close(IntPtr db);

    public static void Exec(string file, string sql)
    {
        if (sqlite3_open(file, out var db) != 0) throw new Exception("open " + file);
        try { if (sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0) throw new Exception("exec"); }
        finally { sqlite3_close(db); }
    }
}
