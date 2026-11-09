namespace ClaudeMultiAccounts.Core;

/// <summary>
/// Where things are on this PC: Claude's own data folder, how to start Claude, and this tool's folder.
///
/// Claude for Windows comes in two shapes. The Microsoft Store / MSIX package
/// (<c>Claude_&lt;publisher&gt;</c>) runs with its AppData virtualized: what it calls
/// <c>%APPDATA%\Claude</c> is really <c>%LOCALAPPDATA%\Packages\Claude_…\LocalCache\Roaming\Claude</c>,
/// and it is started through its execution alias <c>claude-desktop.exe</c>, which passes arguments on.
/// The older Squirrel installer keeps the data at <c>%APPDATA%\Claude</c> and starts from
/// <c>%LOCALAPPDATA%\AnthropicClaude\claude.exe</c>.
/// </summary>
public sealed class Layout
{
    public required string Home { get; init; }
    public required string LiveData { get; init; }
    /// <summary>What starts Claude (the execution alias or the installer's stub); null when not installed.</summary>
    public string? Launcher { get; init; }
    /// <summary>Folder names that identify Claude's own executable among running processes.</summary>
    public string[] AppExeMarkers { get; init; } = Array.Empty<string>();
    /// <summary>Other spellings of the main data folder that a running Claude may print (the virtual one).</summary>
    public string[] LiveDataAliases { get; init; } = Array.Empty<string>();
    /// <summary>Where removed folders go instead of the Recycle Bin (tests only).</summary>
    public string? Trash { get; init; }
    public bool IsPackaged { get; init; }

    public string AccountsRoot => Path.Combine(Home, "accounts");
    public string BackupsRoot => Path.Combine(Home, "backups");
    public string AccountsFile => Path.Combine(Home, "accounts.json");
    public string LogFile => Path.Combine(Home, "activity.log");
    public string LockFile => Path.Combine(Home, ".lock");
    public string SettingsFile => Path.Combine(Home, "settings.json");

    public string FolderOf(Account account) => Path.Combine(AccountsRoot, account.Folder ?? account.Uuid);

    public static Layout System()
    {
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string home = Environment.GetEnvironmentVariable("CMA_HOME") is { Length: > 0 } h
            ? h : Path.Combine(profile, ".claude-multi-accounts");
        string plainData = Path.Combine(roaming, "Claude");

        // The MSIX package: its data lives in the package's LocalCache.
        string? packagedData = null;
        string packages = Path.Combine(local, "Packages");
        if (Directory.Exists(packages))
        {
            foreach (var dir in Directory.EnumerateDirectories(packages, "Claude_*"))
            {
                string candidate = Path.Combine(dir, "LocalCache", "Roaming", "Claude");
                if (File.Exists(Path.Combine(candidate, "config.json"))) { packagedData = candidate; break; }
            }
        }
        string alias = Path.Combine(local, "Microsoft", "WindowsApps", "claude-desktop.exe");
        string squirrel = Path.Combine(local, "AnthropicClaude", "claude.exe");

        string? overrideData = Environment.GetEnvironmentVariable("CMA_CLAUDE_DIR");
        bool packaged = overrideData == null && packagedData != null && File.Exists(alias);
        string liveData = overrideData ?? (packaged ? packagedData! : plainData);
        string? launcher = packaged ? alias : File.Exists(squirrel) ? squirrel : File.Exists(alias) ? alias : null;

        return new Layout
        {
            Home = home,
            LiveData = liveData,
            Launcher = launcher,
            IsPackaged = packaged,
            AppExeMarkers = new[] { @"\WindowsApps\Claude_", @"\AnthropicClaude\", @"\claude-desktop.exe" },
            LiveDataAliases = packaged ? new[] { plainData } : Array.Empty<string>(),
        };
    }

    /// <summary>A path in one spelling, to compare two paths.</summary>
    public static string Normalize(string path)
    {
        try { path = Path.GetFullPath(path.Trim().Trim('"')); } catch { }
        return path.TrimEnd('\\', '/').ToLowerInvariant();
    }
}
