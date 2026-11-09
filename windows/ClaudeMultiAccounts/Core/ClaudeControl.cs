using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace ClaudeMultiAccounts.Core;

/// <summary>Finding, starting and quitting copies of Claude. Tests replace it with a pretend Claude.</summary>
public interface IClaudeControl
{
    /// <summary>The main Claude: the running Claude started without --user-data-dir (or on its usual folder).</summary>
    int? MainPid();
    /// <summary>The running copy of Claude whose --user-data-dir names this folder.</summary>
    int? PidUsing(string dataFolder);
    bool AnyInstanceRunning();
    /// <summary>Asks one copy of Claude to quit, as Windows does when signing out, and waits for it and
    /// its helpers to end. Never force-quits.</summary>
    void Quit(int pid, TimeSpan timeout);
    void LaunchMain(bool inBackground = false);
    void LaunchSide(string dataFolder, bool inBackground = false);
    void Activate(int pid);
    bool Installed { get; }
}

public sealed class SystemClaudeControl : IClaudeControl
{
    readonly Layout layout;
    readonly string liveData;
    readonly HashSet<string> mainFolders;

    public SystemClaudeControl(Layout layout)
    {
        this.layout = layout;
        liveData = Layout.Normalize(layout.LiveData);
        mainFolders = new[] { layout.LiveData }.Concat(layout.LiveDataAliases).Select(Layout.Normalize).ToHashSet();
    }

    public bool Installed => layout.Launcher != null && File.Exists(layout.Launcher);

    sealed record ClaudeProcess(int Pid, int ParentPid, string? DataFolder, string? RawFolder, bool IsHelper);

    static readonly Regex DataDirArg = new(@"--user-data-dir=(?:""([^""]+)""|(\S+))", RegexOptions.Compiled);

    // Reading every process's command line takes a moment; answers within half a second are reused.
    List<ClaudeProcess>? cache;
    DateTime cachedAt;
    readonly object gate = new();

    List<ClaudeProcess> Processes(bool fresh = false)
    {
        lock (gate)
        {
            if (!fresh && cache != null && DateTime.UtcNow - cachedAt < TimeSpan.FromMilliseconds(500)) return cache;
            var list = new List<ClaudeProcess>();
            using var searcher = new ManagementObjectSearcher(
                "SELECT ProcessId, ParentProcessId, ExecutablePath, CommandLine FROM Win32_Process WHERE Name = 'claude.exe'");
            foreach (ManagementObject p in searcher.Get())
            {
                using (p)
                {
                    string exe = p["ExecutablePath"] as string ?? "";
                    string cmd = p["CommandLine"] as string ?? "";
                    // The Claude Code command line is also called claude.exe; only Claude's own app counts.
                    if (!layout.AppExeMarkers.Any(m => exe.Contains(m, StringComparison.OrdinalIgnoreCase)
                                                      || cmd.Contains(m, StringComparison.OrdinalIgnoreCase))) continue;
                    if (exe.Contains(@"\claude-code\", StringComparison.OrdinalIgnoreCase)) continue;
                    var m = DataDirArg.Match(cmd);
                    string? raw = m.Success ? (m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value) : null;
                    list.Add(new ClaudeProcess(Convert.ToInt32(p["ProcessId"]), Convert.ToInt32(p["ParentProcessId"]),
                        raw == null ? null : Layout.Normalize(raw), raw, cmd.Contains("--type=", StringComparison.Ordinal)));
                }
            }
            cache = list;
            cachedAt = DateTime.UtcNow;
            return list;
        }
    }

    public int? MainPid() =>
        Processes().FirstOrDefault(p => !p.IsHelper && (p.DataFolder == null || mainFolders.Contains(p.DataFolder)))?.Pid;

    public int? PidUsing(string dataFolder)
    {
        string folder = Layout.Normalize(dataFolder);
        if (mainFolders.Contains(folder)) return MainPid();
        return Processes().FirstOrDefault(p => !p.IsHelper && p.DataFolder == folder)?.Pid;
    }

    public bool AnyInstanceRunning() => Processes().Any();

    public void Quit(int pid, TimeSpan timeout)
    {
        string? folder = Processes(fresh: true).FirstOrDefault(p => p.Pid == pid)?.DataFolder;
        bool isMain = folder == null || mainFolders.Contains(folder);
        // Electron quits like the File > Quit menu when Windows says the session ends for this app
        // (Claude logs "Windows session ending (close-app) - quitting the app").
        var windows = Native.TopLevelWindows(pid).Where(h => Native.ClassName(h) == "Chrome_WidgetWin_1").ToList();
        if (windows.Count == 0) throw new SwapException("Couldn't find Claude's window to ask it to quit. Nothing was changed.");
        foreach (var h in windows)
        {
            Native.SendMessageTimeout(h, Native.WM_QUERYENDSESSION, IntPtr.Zero, (IntPtr)Native.ENDSESSION_CLOSEAPP, Native.SMTO_ABORTIFHUNG, 5000, out _);
        }
        foreach (var h in windows)
        {
            Native.SendMessageTimeout(h, Native.WM_ENDSESSION, (IntPtr)1, (IntPtr)Native.ENDSESSION_CLOSEAPP, Native.SMTO_ABORTIFHUNG, 5000, out _);
        }
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var all = Processes(fresh: true);
            bool alive = all.Any(p => p.Pid == pid);
            // Its helpers (GPU, network, renderers) name the same data folder; wait for them too.
            bool helpers = all.Any(p => p.IsHelper && (isMain ? p.DataFolder == null || mainFolders.Contains(p.DataFolder) : p.DataFolder == folder));
            if (!alive && !helpers) return;
            Thread.Sleep(300);
        }
        throw new SwapException($"Claude didn't quit within {timeout.TotalSeconds:0} seconds. If it asked to confirm quitting, confirm and try again. Nothing was changed.");
    }

    public void LaunchMain(bool inBackground = false) => Start(null);

    public void LaunchSide(string dataFolder, bool inBackground = false) => Start(dataFolder);

    void Start(string? dataFolder)
    {
        if (!Installed) throw new SwapException("Claude for Windows isn't installed. Install it from claude.ai/download.");
        var info = new ProcessStartInfo(layout.Launcher!) { UseShellExecute = false };
        if (dataFolder != null) info.ArgumentList.Add($"--user-data-dir={dataFolder}");
        // Claude hands its environment to every terminal in its Code tab; leave this tool's own out.
        foreach (var key in info.Environment.Keys.Where(k => k.StartsWith("CMA_", StringComparison.OrdinalIgnoreCase)).ToList())
            info.Environment.Remove(key);
        using var _ = Process.Start(info);
        lock (gate) cache = null;
    }

    /// <summary>Starting Claude again on the same folder brings that copy's window forward
    /// (Electron hands the second start to the running one, even from the tray).</summary>
    public void Activate(int pid)
    {
        var proc = Processes(fresh: true).FirstOrDefault(p => p.Pid == pid);
        if (proc == null) return;
        bool isMain = proc.DataFolder == null || mainFolders.Contains(proc.DataFolder);
        foreach (var h in Native.TopLevelWindows(pid).Where(h => Native.ClassName(h) == "Chrome_WidgetWin_1" && Native.IsWindowVisible(h)))
        {
            Native.ShowWindow(h, Native.SW_RESTORE);
            Native.SetForegroundWindow(h);
        }
        // Passed on exactly as it was first given: Claude finds its running copy by this text.
        Start(isMain ? null : proc.RawFolder);
    }
}

static class Native
{
    public const uint WM_QUERYENDSESSION = 0x0011, WM_ENDSESSION = 0x0016, SMTO_ABORTIFHUNG = 0x0002;
    public const int ENDSESSION_CLOSEAPP = 0x00000001, SW_RESTORE = 9;

    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    public static List<IntPtr> TopLevelWindows(int pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out uint owner);
            if (owner == pid) found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string ClassName(IntPtr hwnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }
}
