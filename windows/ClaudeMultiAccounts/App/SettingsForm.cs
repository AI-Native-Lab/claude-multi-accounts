namespace ClaudeMultiAccounts.App;

sealed class SettingsForm : Form
{
    public SettingsForm(AppModel model)
    {
        var settings = model.Settings;
        Text = "Settings";
        Icon = Theme.AppIcon();
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Theme.Body;
        BackColor = Theme.Window;
        ForeColor = Theme.Text;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(20);

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, Dock = DockStyle.Fill };

        Label Section(string text) => new() { Text = text, Font = Theme.Heading, AutoSize = true, Margin = new Padding(0, 10, 0, 4) };
        Label Note(string text) => new() { Text = text, AutoSize = true, ForeColor = Theme.Secondary, MaximumSize = new Size(470, 0), Margin = new Padding(20, 0, 0, 6) };
        CheckBox Check(string text, bool value, Action<bool> set)
        {
            var box = new CheckBox { Text = text, Checked = value, AutoSize = true, Margin = new Padding(0, 4, 0, 2) };
            box.CheckedChanged += (_, _) => { set(box.Checked); settings.Save(); };
            return box;
        }

        layout.Controls.Add(Section("Claude updates"));
        layout.Controls.Add(Check("Reopen Claude windows that Claude closes to install an update", settings.ReopenAfterUpdates, v => settings.ReopenAfterUpdates = v));
        layout.Controls.Add(Note("Claude's updater only reopens the main Claude. With this on, each account's window comes back too, at the page it was showing."));

        layout.Controls.Add(Section("Switching"));
        layout.Controls.Add(Check("Ask before switching the main Claude", settings.AskBeforeSwitching, v => settings.AskBeforeSwitching = v));

        layout.Controls.Add(Section("This app"));
        layout.Controls.Add(Check("Keep running in the notification area when the window is closed", settings.KeepInTray, v => settings.KeepInTray = v));
        bool startup = false;
        try { startup = AppSettings.StartWithWindows; } catch { }
        var startBox = new CheckBox { Text = "Start with Windows (in the notification area)", Checked = startup, AutoSize = true, Margin = new Padding(0, 4, 0, 2) };
        startBox.CheckedChanged += (_, _) =>
        {
            try { AppSettings.StartWithWindows = startBox.Checked; }
            catch (Exception e) { Prompt.Error(e); }
        };
        layout.Controls.Add(startBox);

        layout.Controls.Add(Section("Folders"));
        var folders = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 4, 0, 0) };
        foreach (var (title, action) in new (string, Action)[]
                 {
                     ("Accounts Folder", model.ShowAccountsFolder),
                     ("Claude's Data Folder", model.ShowClaudeDataFolder),
                     ("Activity Log", model.OpenLog),
                 })
        {
            var b = new Button { Text = title, Margin = new Padding(0, 0, 8, 0) };
            Theme.StyleButton(b);
            b.Click += (_, _) => action();
            folders.Controls.Add(b);
        }
        layout.Controls.Add(folders);
        var paths = Note($"Accounts: {model.Manager.Layout.Home}\nClaude: {model.Manager.Layout.LiveData}");
        paths.Margin = new Padding(0, 8, 0, 0);
        layout.Controls.Add(paths);

        layout.Controls.Add(new Label
        {
            Text = $"Claude Multi-Accounts {Application.ProductVersion.Split('+')[0]} for Windows · beta · AI Native Lab\nNever uses Claude's own Log out and sends nothing to Anthropic. Sign-ins stay on this PC.",
            AutoSize = true, ForeColor = Theme.Secondary, Font = Theme.Small, MaximumSize = new Size(490, 0), Margin = new Padding(0, 16, 0, 8),
        });
        var close = new Button { Text = "Done", DialogResult = DialogResult.OK };
        Theme.StyleButton(close, prominent: true);
        close.Anchor = AnchorStyles.Right;
        layout.Controls.Add(close);
        AcceptButton = close;
        CancelButton = close;
        Controls.Add(layout);
    }
}
