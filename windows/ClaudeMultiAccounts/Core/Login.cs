using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeMultiAccounts.Core;

public enum ExpiryKind { None, UntilQuit, Until, Unknown }

/// <summary>When a claude.ai sign-in expires. <see cref="ExpiryKind.Unknown"/>: the cookie database
/// is held open by a running Claude, so only the config keys say it is signed in.</summary>
public readonly record struct Expiry(ExpiryKind Kind, DateTime? Date = null)
{
    public static readonly Expiry None = new(ExpiryKind.None);
    public bool Valid => Kind != ExpiryKind.None;

    public string Describe() => Kind switch
    {
        ExpiryKind.None => "signed out / expired",
        ExpiryKind.UntilQuit => "until Claude quits",
        ExpiryKind.Until => "until " + Date!.Value.ToString("d MMM yyyy"),
        _ => "",
    };
}

/// <summary>
/// The sign-in inside a Claude data folder, and copying it between folders.
///
/// Claude for Windows keeps its sign-in in two places in its data folder:
///
///     Network\Cookies   the claude.ai web session (the sessionKey cookies)
///     config.json       oauth:tokenCache, oauth:tokenCacheV2 and lastKnownAccountUuid
///
/// Both are encrypted with a key kept in the folder's own <c>Local State</c> file (os_crypt.encrypted_key,
/// itself protected with Windows DPAPI for this Windows user). Unlike the Mac, every data folder would
/// make its own key, so every account folder gets a copy of the main Claude's <c>Local State</c>: then
/// one key opens every sign-in, wherever it is put. Nothing here decrypts or reads those values: only
/// cookie names, hosts and expiry dates.
///
/// An account folder that has never been opened in its own window holds the cookie files, <c>auth.json</c>
/// (the three config keys) and <c>Local State</c>. Once opened, it is a full Claude data folder whose
/// <c>config.json</c> holds the keys instead.
/// </summary>
public static class Login
{
    public static readonly string[] ConfigKeys = { "oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid" };
    public const string UuidKey = "lastKnownAccountUuid";
    public static readonly string[] CookieFiles =
    {
        @"Network\Cookies", @"Network\Cookies-journal", @"Network\Cookies-wal", @"Network\Cookies-shm",
    };
    public const string LocalState = "Local State";
    static readonly string[] SessionCookies = { "sessionKey", "sessionKeyV2", "sessionKeyV3" };
    static readonly string[] Hosts = { "claude.ai", ".claude.ai" };
    /// <summary>Plain settings copied into a new window's folder so it looks like the main Claude.</summary>
    static readonly string[] SharedSettings = { "locale", "userThemeMode" };

    // MARK: Reading

    /// <summary>When the claude.ai sign-in cookie in a data folder expires.</summary>
    public static Expiry ExpiryIn(string folder)
    {
        string cookies = Path.Combine(folder, "Network", "Cookies");
        if (!File.Exists(cookies)) return Expiry.None;
        try
        {
            // A running Claude opens its cookie database without sharing it.
            using var probe = new FileStream(cookies, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        }
        catch (IOException) { return new Expiry(ExpiryKind.Unknown); }
        catch (UnauthorizedAccessException) { return new Expiry(ExpiryKind.Unknown); }

        var rows = Sqlite.SessionCookieExpiries(cookies, Hosts, SessionCookies);
        if (rows == null) return new Expiry(ExpiryKind.Unknown);
        Expiry best = Expiry.None;
        foreach (var (expiresUtc, hasExpires) in rows)
        {
            if (!hasExpires) return new Expiry(ExpiryKind.UntilQuit);
            // Chrome time: microseconds since 1601-01-01 UTC.
            var date = DateTime.FromFileTimeUtc(expiresUtc * 10).ToLocalTime();
            if (date > DateTime.Now && (best.Date == null || date > best.Date)) best = new Expiry(ExpiryKind.Until, date);
        }
        return best;
    }

    /// <summary>The sign-in keys of a data folder: from config.json, or auth.json in an account folder
    /// that has never been opened in its own window. Null when there are none.</summary>
    public static JsonObject? Keys(string folder)
    {
        foreach (var name in new[] { "config.json", "auth.json" })
        {
            string path = Path.Combine(folder, name);
            if (!File.Exists(path)) continue;
            JsonObject obj;
            try { obj = ReadJson(path); } catch { continue; }
            var keys = new JsonObject();
            foreach (var key in ConfigKeys)
                if (obj[key] is JsonNode value) keys[key] = value.DeepClone();
            return keys.Count == 0 ? null : keys;
        }
        return null;
    }

    public static string? AccountUuid(string folder) => Keys(folder)?[UuidKey]?.GetValue<string>();

    public static bool HasSignIn(string folder) => Keys(folder) != null;

    /// <summary>The DPAPI-protected key that opens the cookies and tokens of a folder.</summary>
    public static string? EncryptionKey(string folder)
    {
        string path = Path.Combine(folder, LocalState);
        if (!File.Exists(path)) return null;
        try { return ReadJson(path)["os_crypt"]?["encrypted_key"]?.GetValue<string>(); } catch { return null; }
    }

    // MARK: Copying

    /// <summary>Makes <paramref name="destination"/>'s sign-in a copy of <paramref name="source"/>'s,
    /// leaving every other file and setting alone. <paramref name="source"/> null signs it out (on this PC only).</summary>
    public static void Copy(string? source, string destination)
    {
        var keys = source != null ? Keys(source) : new JsonObject();
        if (source != null && keys == null) throw new SwapException($"{source} holds no sign-in.");
        Directory.CreateDirectory(destination);

        if (source != null)
        {
            // The sign-in only works where the same key opens it.
            string? from = EncryptionKey(source), to = EncryptionKey(destination);
            if (from == null) throw new SwapException($"{source} has no “{LocalState}”, so its sign-in can't be read anywhere else.");
            if (to == null) File.Copy(Path.Combine(source, LocalState), Path.Combine(destination, LocalState));
            else if (to != from)
                throw new SwapException($"The sign-in in {source} is locked with a different key than {destination} uses. Nothing was changed.");
        }

        // Remove every cookie sidecar first: a leftover journal from another account's database
        // would be replayed into the copied one.
        foreach (var name in CookieFiles) TryDelete(Path.Combine(destination, name));
        if (source != null)
        {
            foreach (var name in CookieFiles)
            {
                string from = Path.Combine(source, name);
                if (!File.Exists(from)) continue;
                string to = Path.Combine(destination, name);
                Directory.CreateDirectory(Path.GetDirectoryName(to)!);
                string tmp = Path.Combine(Path.GetDirectoryName(to)!, $".{Path.GetFileName(name)}.swap-tmp");
                TryDelete(tmp);
                File.Copy(from, tmp);
                File.Move(tmp, to, overwrite: false);
            }
        }

        string config = Path.Combine(destination, "config.json");
        if (File.Exists(config))
        {
            var obj = ReadJson(config);
            foreach (var key in ConfigKeys) obj.Remove(key);
            foreach (var (key, value) in keys!) obj[key] = value?.DeepClone();
            WriteJson(obj, config);
            // Claude wipes a config.json it can't parse, so prove this one parses.
            ReadJson(config);
            TryDelete(Path.Combine(destination, "auth.json"));
        }
        else
        {
            WriteJson(keys!, Path.Combine(destination, "auth.json"));
        }
    }

    /// <summary>Turns an account folder into a data folder Claude can open: its auth.json keys move into a
    /// config.json, with the main Claude's language and theme, and it gets the main Claude's key.</summary>
    public static void PrepareForWindow(string folder, string mainData)
    {
        Directory.CreateDirectory(folder);
        string localState = Path.Combine(folder, LocalState);
        if (!File.Exists(localState))
        {
            string mainState = Path.Combine(mainData, LocalState);
            if (!File.Exists(mainState)) throw new SwapException($"Claude's “{LocalState}” is missing from {mainData}.");
            File.Copy(mainState, localState);
        }
        string config = Path.Combine(folder, "config.json");
        string auth = Path.Combine(folder, "auth.json");
        if (File.Exists(config)) return;
        var obj = new JsonObject();
        try
        {
            var main = ReadJson(Path.Combine(mainData, "config.json"));
            foreach (var key in SharedSettings)
                if (main[key] is JsonNode v) obj[key] = v.DeepClone();
        }
        catch { }
        if (File.Exists(auth))
            foreach (var (key, value) in ReadJson(auth)) obj[key] = value?.DeepClone();
        WriteJson(obj, config);
        TryDelete(auth);
    }

    // MARK: JSON

    public static JsonObject ReadJson(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return JsonNode.Parse(stream) as JsonObject ?? throw new SwapException($"{path} isn't a JSON object.");
    }

    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };

    public static void WriteJson(JsonObject obj, string path) => Files.WriteAtomically(path, obj.ToJsonString(Pretty));

    static void TryDelete(string path) { try { File.Delete(path); } catch (DirectoryNotFoundException) { } }
}

/// <summary>Just enough SQLite to read cookie expiry dates, through the copy built into Windows (winsqlite3.dll).</summary>
static class Sqlite
{
    const string Dll = "winsqlite3.dll";
    const int SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_OPEN_READONLY = 1, SQLITE_OPEN_URI = 0x40;

    [DllImport(Dll)] static extern int sqlite3_open_v2([MarshalAs(UnmanagedType.LPUTF8Str)] string filename, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Dll)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Dll)] static extern int sqlite3_prepare_v2(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, int n, out IntPtr stmt, IntPtr tail);
    [DllImport(Dll)] static extern int sqlite3_bind_text(IntPtr stmt, int index, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int n, IntPtr destructor);
    [DllImport(Dll)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Dll)] static extern long sqlite3_column_int64(IntPtr stmt, int col);
    [DllImport(Dll)] static extern int sqlite3_finalize(IntPtr stmt);

    /// <summary>(expires_utc, has_expires) of each matching cookie with a value; null when unreadable.</summary>
    public static List<(long, bool)>? SessionCookieExpiries(string path, string[] hosts, string[] names)
    {
        string uri = "file:" + Uri.EscapeDataString(path.Replace('\\', '/')).Replace("%2F", "/").Replace("%3A", ":") + "?mode=ro&immutable=1";
        try
        {
            if (sqlite3_open_v2(uri, out var db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, IntPtr.Zero) != SQLITE_OK)
            {
                sqlite3_close(db);
                return null;
            }
            try
            {
                string sql = "SELECT expires_utc, has_expires FROM cookies"
                    + $" WHERE host_key IN ({string.Join(",", hosts.Select(_ => "?"))})"
                    + $" AND name IN ({string.Join(",", names.Select(_ => "?"))})"
                    + " AND (length(encrypted_value) > 0 OR length(value) > 0)";
                if (sqlite3_prepare_v2(db, sql, -1, out var stmt, IntPtr.Zero) != SQLITE_OK) return null;
                try
                {
                    int i = 1;
                    foreach (var v in hosts.Concat(names)) sqlite3_bind_text(stmt, i++, v, -1, new IntPtr(-1));
                    var rows = new List<(long, bool)>();
                    while (sqlite3_step(stmt) == SQLITE_ROW)
                        rows.Add((sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1) != 0));
                    return rows;
                }
                finally { sqlite3_finalize(stmt); }
            }
            finally { sqlite3_close(db); }
        }
        catch (DllNotFoundException) { return null; }
        catch (EntryPointNotFoundException) { return null; }
    }
}
