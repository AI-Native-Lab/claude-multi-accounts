using ClaudeMultiAccounts.Core;

/// <summary>Checks the real Claude on this PC without touching the main Claude: reads its state, then starts,
/// finds, brings forward and quits a throwaway Claude window on a temporary folder.
/// Run: dotnet run --project windows\CoreTests -- --real</summary>
static class RealClaude
{
    public static int Run()
    {
        var layout = Layout.System();
        Console.WriteLine($"Claude data:  {layout.LiveData}");
        Console.WriteLine($"Launcher:     {layout.Launcher} (packaged: {layout.IsPackaged})");
        var control = new SystemClaudeControl(layout);
        var manager = new AccountManager(new Layout
        {
            Home = Path.Combine(Path.GetTempPath(), "cma-real-" + Guid.NewGuid().ToString("N")[..6]),
            LiveData = layout.LiveData, Launcher = layout.Launcher, AppExeMarkers = layout.AppExeMarkers,
            LiveDataAliases = layout.LiveDataAliases, IsPackaged = layout.IsPackaged,
        }, control);
        var main = manager.MainState();
        Console.WriteLine($"Main Claude:  pid {main.Pid?.ToString() ?? "-"}, signed in {main.SignedIn}, account {main.Uuid?[..8]}…, expiry {main.LoginExpires.Kind}");
        Console.WriteLine($"Local State key present: {Login.EncryptionKey(layout.LiveData) != null}");

        string probe = Path.Combine(Path.GetTempPath(), "cma-probe-" + Guid.NewGuid().ToString("N")[..6]);
        try
        {
            Login.PrepareForWindow(probe, layout.LiveData);
            Console.WriteLine($"Same key in probe: {Login.EncryptionKey(probe) == Login.EncryptionKey(layout.LiveData)}");
            control.LaunchSide(probe);
            int? pid = null;
            for (int i = 0; i < 100 && pid == null; i++) { Thread.Sleep(200); pid = control.PidUsing(probe); }
            Console.WriteLine($"Probe window: pid {pid?.ToString() ?? "NOT FOUND"}; main still pid {control.MainPid()}");
            if (pid == null) return 1;
            Thread.Sleep(8000);
            control.Activate(pid.Value);
            Thread.Sleep(3000);
            Console.WriteLine($"After activate: still one copy on the probe? {control.PidUsing(probe) == pid}");
            var started = DateTime.UtcNow;
            control.Quit(pid.Value, TimeSpan.FromSeconds(60));
            Console.WriteLine($"Quit cleanly in {(DateTime.UtcNow - started).TotalSeconds:0.0} s; probe running: {control.PidUsing(probe) != null}; main still pid {control.MainPid()}");
            string log = Path.Combine(probe, "logs", "main.log");
            if (File.Exists(log))
                Console.WriteLine("Probe log: " + File.ReadLines(log).LastOrDefault(l => l.Contains("quitting", StringComparison.OrdinalIgnoreCase)));
            return 0;
        }
        catch (Exception e) { Console.WriteLine("FAILED: " + e.Message); return 1; }
        finally
        {
            Thread.Sleep(1500);
            try { Directory.Delete(probe, true); } catch (Exception e) { Console.WriteLine("cleanup: " + e.Message); }
        }
    }
}
