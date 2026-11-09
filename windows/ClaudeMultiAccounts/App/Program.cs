using ClaudeMultiAccounts.Core;

namespace ClaudeMultiAccounts.App;

static class Program
{
    const string InstanceName = "AINativeLab.ClaudeMultiAccounts";

    [STAThread]
    static void Main(string[] args)
    {
        // One copy at a time: a second start brings the first one's window forward.
        using var mutex = new Mutex(true, InstanceName, out bool first);
        using var show = new EventWaitHandle(false, EventResetMode.AutoReset, InstanceName + ".Show");
        if (!first)
        {
            show.Set();
            return;
        }

        ApplicationConfiguration.Initialize();
        // The model hands results to the UI through this; WinForms would only install it with the first window.
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        var layout = Layout.System();

        // --render-screenshot <file.png>: draws the main window as it is now and quits (for the README).
        int shot = Array.IndexOf(args, "--render-screenshot");
        if (shot >= 0 && shot + 1 < args.Length)
        {
            var shotModel = new AppModel(new AccountManager(layout), AppSettings.Load(layout.SettingsFile));
            using var shotForm = new MainForm(shotModel, startHidden: false, live: false);
            shotForm.StartPosition = FormStartPosition.Manual;
            shotForm.Location = new Point(-4000, -4000);
            shotForm.Show();
            shotModel.RefreshNow();
            Application.DoEvents();
            using var bitmap = new Bitmap(shotForm.Width, shotForm.Height);
            shotForm.DrawToBitmap(bitmap, new Rectangle(Point.Empty, shotForm.Size));
            bitmap.Save(args[shot + 1], System.Drawing.Imaging.ImageFormat.Png);
            return;
        }
        var manager = new AccountManager(layout);
        var settings = AppSettings.Load(layout.SettingsFile);
        var model = new AppModel(manager, settings);
        var form = new MainForm(model, startHidden: args.Contains("--background"));

        var listener = new Thread(() =>
        {
            while (true)
            {
                show.WaitOne();
                try { form.BeginInvoke(form.ShowWindow); } catch { return; }
            }
        }) { IsBackground = true };
        listener.Start();

        // A failure in a click handler shows as a message instead of closing the app.
        Application.ThreadException += (_, e) => Prompt.Error(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            AccountManager.AppendLog($"Crash: {e.ExceptionObject}", layout.LogFile);
        Application.Run(form);
    }
}
