using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClaudeMultiAccounts.Core;

/// <summary>A Claude account this tool knows. Its sign-in is kept in its own folder (see <see cref="Layout"/>).</summary>
public sealed class Account
{
    [JsonPropertyName("uuid")] public string Uuid { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>When its sign-in was last saved, in local time ("2026-10-21T09:30:00").</summary>
    [JsonPropertyName("savedAt"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? SavedAt { get; set; }
    /// <summary>The folder's name under accounts\ when it isn't the uuid.</summary>
    [JsonPropertyName("folder"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Folder { get; set; }

    [JsonIgnore]
    public DateTime? SavedDate => SavedAt != null && DateTime.TryParseExact(SavedAt, Registry.Format,
        CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var d) ? d : null;

    public Account Clone() => (Account)MemberwiseClone();
}

/// <summary>accounts.json: the names and order of the accounts. Same file format as the macOS app.</summary>
public static class Registry
{
    public const string Format = "yyyy-MM-dd'T'HH:mm:ss";

    sealed class FileShape
    {
        [JsonPropertyName("version")] public int Version { get; set; } = 1;
        [JsonPropertyName("accounts")] public List<Account> Accounts { get; set; } = new();
    }

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static List<Account> Load(string path)
    {
        if (!File.Exists(path)) return new();
        return JsonSerializer.Deserialize<FileShape>(File.ReadAllText(path))?.Accounts ?? new();
    }

    public static void Save(List<Account> accounts, string path)
    {
        Files.WriteAtomically(path, JsonSerializer.Serialize(new FileShape { Accounts = accounts }, Options));
    }

    public static string Now() => DateTime.Now.ToString(Format, CultureInfo.InvariantCulture);
}

public static class AccountListExtensions
{
    /// <summary>"Account 3", or the next free number.</summary>
    public static string DefaultName(this List<Account> accounts)
    {
        var taken = accounts.Select(a => a.Name.ToLowerInvariant()).ToHashSet();
        int n = accounts.Count + 1;
        while (taken.Contains($"account {n}")) n++;
        return $"Account {n}";
    }

    /// <summary>Finds an account by list number, name (ignoring case), uuid or a uuid prefix of 4+ characters.</summary>
    public static Account Find(this List<Account> accounts, string query)
    {
        if (int.TryParse(query, out int number) && number >= 1 && number <= accounts.Count) return accounts[number - 1];
        var match = accounts.FirstOrDefault(a => string.Equals(a.Name, query, StringComparison.OrdinalIgnoreCase) || a.Uuid == query);
        if (match != null) return match;
        var prefixed = accounts.Where(a => query.Length >= 4 && a.Uuid.StartsWith(query, StringComparison.Ordinal)).ToList();
        if (prefixed.Count == 1) return prefixed[0];
        string names = string.Join(", ", accounts.Select((a, i) => $"{i + 1}. {a.Name}"));
        throw new SwapException($"No saved account “{query}”. Saved: {(names.Length == 0 ? "none" : names)}.");
    }
}

public static class Files
{
    /// <summary>Writes a file atomically: a temporary file next to it, then a replace.</summary>
    public static void WriteAtomically(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string tmp = Path.Combine(Path.GetDirectoryName(path)!, $".{Path.GetFileName(path)}.{Environment.ProcessId}.tmp");
        using (var stream = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        using (var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false)))
        {
            writer.Write(text);
            writer.Flush();
            stream.Flush(true);
        }
        File.Move(tmp, path, overwrite: true);
    }

    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    /// <summary>A real folder, not a junction or link to one.</summary>
    public static bool IsRealFolder(string path)
    {
        var info = new DirectoryInfo(path);
        return info.Exists && !info.Attributes.HasFlag(FileAttributes.ReparsePoint);
    }

    public static long FolderSize(string path)
    {
        long total = 0;
        try
        {
            foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", new EnumerationOptions
                     { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint }))
                total += f.Length;
        }
        catch { }
        return total;
    }

    public static string FormatSize(long bytes)
    {
        string[] units = { "bytes", "KB", "MB", "GB", "TB" };
        double v = bytes; int i = 0;
        while (v >= 1000 && i < units.Length - 1) { v /= 1000; i++; }
        return i == 0 ? $"{bytes} bytes" : v >= 100 ? $"{v:0} {units[i]}" : $"{v:0.#} {units[i]}";
    }
}

public sealed class SwapException : Exception
{
    public SwapException(string message) : base(message) { }
}
