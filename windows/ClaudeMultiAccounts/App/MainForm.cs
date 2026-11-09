using System.Drawing.Drawing2D;
using ClaudeMultiAccounts.Core;

namespace ClaudeMultiAccounts.App;

/// <summary>The main window: the account in the main Claude, every saved account, and what can be done with each.</summary>
sealed class MainForm : Form
{
    readonly AppModel model;
    readonly Label headline = new() { AutoSize = true, Font = Theme.Title, ForeColor = Theme.Text };
    readonly Label subheadline = new() { AutoSize = true, ForeColor = Theme.Secondary };
    readonly Button addButton = new() { Text = "+  Add Account  ▾" };
    readonly Button settingsButton = new() { Text = "Settings" };
    readonly FlowLayoutPanel list = new()
    {
        Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true,
        Padding = new Padding(20, 16, 20, 20),
    };
    readonly NotifyIcon tray = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 3000 };
    readonly System.Windows.Forms.Timer sizeTimer = new() { Interval = 600_000 };
    string drawn = "";
    bool quitting;

    public MainForm(AppModel model, bool startHidden, bool live = true)
    {
        this.model = model;
        Text = "Claude Multi-Accounts";
        Icon = Theme.AppIcon();
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = Theme.Body;
        BackColor = Theme.Window;
        ForeColor = Theme.Text;
        ClientSize = new Size(760, 560);
        MinimumSize = new Size(640, 420);
        StartPosition = FormStartPosition.CenterScreen;
        Prompt.Owner = this;

        Controls.Add(list);
        Controls.Add(BuildHeader());

        tray.Icon = Theme.AppIcon();
        tray.Text = "Claude Multi-Accounts";
        tray.Visible = live;
        tray.ContextMenuStrip = new ContextMenuStrip();
        tray.ContextMenuStrip.Opening += (_, e) => { BuildTrayMenu(tray.ContextMenuStrip); e.Cancel = false; };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };

        model.Changed += Render;
        timer.Tick += (_, _) => model.Refresh();
        sizeTimer.Tick += (_, _) => model.RefreshSizes();
        Load += (_, _) =>
        {
            if (!live) return;
            model.Refresh();
            model.RefreshSizes();
            timer.Start();
            sizeTimer.Start();
            if (startHidden) BeginInvoke(Hide);
        };
        Render();
    }

    Control BuildHeader()
    {
        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Top, Height = 84, ColumnCount = 4, RowCount = 1, Padding = new Padding(20, 16, 20, 12),
            BackColor = Theme.Card,
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 62));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var icon = new PictureBox { Image = new Icon(Theme.AppIcon(), 48, 48).ToBitmap(), SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(48, 48), Margin = new Padding(0, 2, 12, 0) };
        var titles = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 0) };
        titles.Controls.Add(headline);
        titles.Controls.Add(subheadline);
        Theme.StyleButton(addButton, prominent: true);
        Theme.StyleButton(settingsButton);
        addButton.Margin = new Padding(8, 10, 0, 0);
        settingsButton.Margin = new Padding(8, 10, 0, 0);
        var addMenu = new ContextMenuStrip();
        addMenu.Items.Add("Sign In in a New Window…", null, (_, _) => model.AddInWindow());
        addMenu.Items.Add("Sign In in the Main Claude (Restarts It)…", null, (_, _) => model.AddInMain());
        addButton.Click += (_, _) => addMenu.Show(addButton, new Point(0, addButton.Height));
        settingsButton.Click += (_, _) => ShowSettings();
        header.Controls.Add(icon, 0, 0);
        header.Controls.Add(titles, 1, 0);
        header.Controls.Add(addButton, 2, 0);
        header.Controls.Add(settingsButton, 3, 0);
        header.Paint += (_, e) => { using var pen = new Pen(Theme.Border); e.Graphics.DrawLine(pen, 0, header.Height - 1, header.Width, header.Height - 1); };
        return header;
    }

    /// <summary>Redraws the list when what it shows has changed.</summary>
    void Render()
    {
        headline.Text = model.Headline;
        subheadline.Text = model.Subheadline;
        addButton.Enabled = model.Busy == null && model.Snapshot != null;
        tray.Text = Truncate(model.Busy ?? model.Headline, 63);

        string signature = string.Join("|", new object?[]
        {
            model.Busy, model.Problem, model.Snapshot?.MainIsUnnamed,
            string.Join(";", model.Statuses.Select(s => $"{s.Account.Uuid},{s.Account.Name},{s.Place},{s.WindowPid},{s.LoginExpires},{s.HasSavedSignIn},{s.Account.SavedAt},{(model.Sizes.TryGetValue(s.Account.Uuid, out var z) ? z : -1)}")),
            string.Join(";", (model.Snapshot?.NewWindows ?? new()).Select(w => $"{w.Folder},{w.Pid},{w.Name}")),
            model.Snapshot == null,
        });
        if (signature == drawn) return;
        drawn = signature;

        list.SuspendLayout();
        var old = list.Controls.Cast<Control>().ToList();
        list.Controls.Clear();
        foreach (var c in old) c.Dispose();
        int width = Math.Max(400, list.ClientSize.Width - list.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);

        void Add(Control c) { c.Width = width; c.Margin = new Padding(0, 0, 0, 10); list.Controls.Add(c); }

        if (model.Problem != null) Add(new Banner(Theme.Orange, model.Problem));
        if (model.Snapshot?.MainIsUnnamed == true)
            Add(new Banner(Theme.Orange, "Claude is signed in to an account this app hasn't named yet.", ("Name It…", model.NameMainAccount)));
        if (model.Statuses.FirstOrDefault(s => s.IsSignedInTwice) is AccountStatus twice)
            Add(new Banner(Theme.Orange, $"“{twice.Account.Name}” is signed in both in the main Claude and in its own window. Close that window before switching.",
                ("Close Window", () => model.CloseWindow(twice))));
        foreach (var window in model.Snapshot?.NewWindows ?? new())
        {
            string who = window.Name != null ? $"“{window.Name}”" : "another account";
            if (window.Pid != null)
                Add(new Banner(Theme.Blue, $"A new Claude window is open to sign in to {who}. It joins this list once signed in (within about 30 seconds).",
                    ("Show", () => model.OpenNewWindow(window)), ("Close", () => model.CloseNewWindow(window))));
            else
                Add(new Banner(Theme.Gray, $"The window to sign in to {who} was closed before signing in.",
                    ("Open Again", () => model.OpenNewWindow(window)), ("Discard", () => model.DiscardNewWindow(window))));
        }
        if (model.Busy != null) Add(new Banner(Theme.Accent, "⏳  " + model.Busy));

        if (model.Snapshot != null && model.Statuses.Count == 0)
            Add(new Label
            {
                Text = "No saved accounts yet. Use “Add Account” to sign in to another one in its own window.",
                ForeColor = Theme.Secondary, TextAlign = ContentAlignment.MiddleCenter, Height = 90,
            });
        foreach (var status in model.Statuses) Add(new AccountCard(model, status));
        Add(new Label
        {
            Text = "Every account stays signed in. Open Side by Side runs an account in its own Claude window, with its session history, next to the main Claude, so you can use both at once. Switch puts an account in the main Claude instead, which restarts in a few seconds; Code sessions that are running stop.",
            ForeColor = Theme.Secondary, Font = Theme.Small, AutoSize = true, MaximumSize = new Size(width, 0), Margin = new Padding(0, 4, 0, 0),
        });
        list.ResumeLayout();
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        if (list == null) return;
        int width = Math.Max(400, list.ClientSize.Width - list.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth);
        foreach (Control c in list.Controls)
        {
            if (c is Label { AutoSize: true } l) l.MaximumSize = new Size(width, 0);
            else c.Width = width;
        }
    }

    static string Truncate(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    public void ShowWindow()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        model.Refresh();
    }

    void ShowSettings()
    {
        using var form = new SettingsForm(model);
        form.ShowDialog(this);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!quitting && model.Settings.KeepInTray && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        tray.Visible = false;
        base.OnFormClosing(e);
    }

    public void Quit()
    {
        quitting = true;
        tray.Visible = false;
        Application.Exit();
    }

    /// <summary>The notification-area menu: accounts to open side by side with one click, then switching the main Claude.</summary>
    void BuildTrayMenu(ContextMenuStrip menu)
    {
        model.Refresh();
        menu.Items.Clear();
        bool idle = model.Busy == null && model.Snapshot != null;
        menu.Items.Add(new ToolStripMenuItem(model.Busy ?? model.Headline) { Enabled = false });
        if (model.Busy == null && model.Subheadline.Length > 0) menu.Items.Add(new ToolStripMenuItem(model.Subheadline) { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Open Claude Multi-Accounts…", null, (_, _) => ShowWindow()) { Font = new Font(menu.Font, FontStyle.Bold) });
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem("Open Side by Side") { Enabled = false });
        if (model.Statuses.Count == 0) menu.Items.Add(new ToolStripMenuItem("No saved accounts yet") { Enabled = false });
        foreach (var status in model.Statuses)
        {
            bool expired = status.Place == Place.Saved && !status.LoginExpires.Valid;
            string title = "    " + status.Account.Name + status.Place switch
            {
                Place.Main => "  (main Claude)",
                Place.Window => "  (own window)",
                Place.Saved when expired => "  (sign-in expired)",
                Place.NotSaved => "  (not saved yet)",
                _ => "",
            };
            bool open = status.Place is Place.Main or Place.Window;
            var s = status;
            menu.Items.Add(new ToolStripMenuItem(title, null, (_, _) =>
            {
                if (s.Place == Place.Main) model.OpenMain();
                else if (s.Place == Place.Window) model.ShowWindow(s);
                else model.OpenWindow(s);
            }) { Checked = open, Enabled = idle && (open || (status.Place == Place.Saved && !expired)) });
        }
        menu.Items.Add(new ToolStripMenuItem("Sign In to Another Account in a New Window…", null, (_, _) => model.AddInWindow()) { Enabled = idle });
        var windows = model.Statuses.Where(s => s.Place == Place.Window).ToList();
        if (windows.Count > 0)
        {
            var close = new ToolStripMenuItem("Close Window") { Enabled = idle };
            foreach (var w in windows) close.DropDownItems.Add(w.Account.Name, null, (_, _) => model.CloseWindow(w));
            menu.Items.Add(close);
        }

        menu.Items.Add(new ToolStripSeparator());
        var switching = new ToolStripMenuItem("Switch Main Claude") { Enabled = idle };
        if (model.Statuses.Count == 0) switching.DropDownItems.Add(new ToolStripMenuItem("No saved accounts yet") { Enabled = false });
        foreach (var status in model.Statuses)
        {
            string title = status.Account.Name + status.Place switch
            {
                Place.Window => "  (in its own window)",
                Place.Saved when !status.LoginExpires.Valid => "  (sign-in expired)",
                Place.NotSaved => "  (not saved yet)",
                _ => "",
            };
            var s = status;
            switching.DropDownItems.Add(new ToolStripMenuItem(title, null, (_, _) => model.SwitchTo(s))
            {
                Checked = status.Place == Place.Main,
                Enabled = status.Place == Place.Main || status.HasSavedSignIn,
            });
        }
        switching.DropDownItems.Add(new ToolStripSeparator());
        switching.DropDownItems.Add("Sign In to Another Account (Restarts Claude)…", null, (_, _) => model.AddInMain());
        menu.Items.Add(switching);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Settings…", null, (_, _) => { ShowWindow(); ShowSettings(); });
        menu.Items.Add("Quit Claude Multi-Accounts", null, (_, _) => Quit());
    }
}

/// <summary>A notice above the accounts.</summary>
sealed class Banner : Panel
{
    readonly Color tint;

    public Banner(Color tint, string text, params (string Label, Action Action)[] buttons)
    {
        this.tint = tint;
        DoubleBuffered = true;
        Padding = new Padding(14, 10, 10, 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = buttons.Length + 1, RowCount = 1, BackColor = Color.Transparent };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < buttons.Length; i++) layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var label = new Label { Text = text, AutoSize = true, ForeColor = Theme.Text, Anchor = AnchorStyles.Left, Margin = new Padding(0, 6, 8, 6) };
        layout.Controls.Add(label, 0, 0);
        int col = 1;
        foreach (var (title, action) in buttons)
        {
            var b = new Button { Text = title, Anchor = AnchorStyles.Right, Margin = new Padding(6, 0, 0, 0) };
            Theme.StyleButton(b);
            b.Click += (_, _) => action();
            layout.Controls.Add(b, col++, 0);
        }
        Controls.Add(layout);
        Height = 54;
        Resize += (_, _) =>
        {
            int buttonsWidth = layout.Controls.OfType<Button>().Sum(b => b.PreferredSize.Width + 6);
            label.MaximumSize = new Size(Math.Max(100, Width - Padding.Horizontal - buttonsWidth - 12), 0);
            Height = Math.Max(54, label.PreferredHeight + Padding.Vertical + 12);
        };
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(Parent?.BackColor ?? Theme.Window);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 8);
        using var brush = new SolidBrush(Theme.Tint(tint, 0.12));
        e.Graphics.FillPath(brush, path);
    }
}

/// <summary>One saved account.</summary>
sealed class AccountCard : Panel
{
    static readonly Color[] AvatarColors =
    {
        Color.FromArgb(217, 120, 87), Color.FromArgb(0, 150, 136), Color.FromArgb(92, 107, 192), Color.FromArgb(216, 27, 96),
        Color.FromArgb(142, 36, 170), Color.FromArgb(67, 160, 71), Color.FromArgb(30, 136, 229), Color.FromArgb(245, 124, 0),
    };

    readonly AccountStatus status;
    readonly Color? highlight;

    public AccountCard(AppModel model, AccountStatus status)
    {
        this.status = status;
        DoubleBuffered = true;
        Height = 78;
        Padding = new Padding(70, 12, 12, 12);
        highlight = status.Place switch { Place.Main => Theme.Accent, Place.Window => Theme.Blue, _ => null };
        bool expired = status.Place != Place.NotSaved && !status.LoginExpires.Valid;

        var (badgeText, badgeColor) = status.Place switch
        {
            Place.Main => status.IsSignedInTwice ? ("Main Claude · also in a window", Theme.Orange) : ("Main Claude", Theme.Green),
            Place.Window => ("Own window", Theme.Blue),
            Place.Saved => expired ? ("Sign-in expired", Theme.Orange) : ("Saved", Theme.Gray),
            _ => ("Not saved yet", Theme.Orange),
        };

        var details = new List<string>();
        if (status.Place == Place.NotSaved) details.Add("Saved the first time the main Claude switches away from it");
        else if (status.Place == Place.Saved && expired) details.Add("Switch to it, then sign in again");
        else if (AppModel.Describe(status.LoginExpires) is { Length: > 0 } d) details.Add($"Signed in {d}");
        else details.Add("Signed in");
        if (status.Place == Place.Saved && status.Account.SavedDate is DateTime saved) details.Add($"saved {Ago(saved)}");
        if (status.Place != Place.Main && model.Sizes.TryGetValue(status.Account.Uuid, out long size)) details.Add(Files.FormatSize(size));

        var text = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, BackColor = Color.Transparent };
        var top = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 2, 0, 2), BackColor = Color.Transparent };
        top.Controls.Add(new Label { Text = status.Account.Name, AutoSize = true, Font = Theme.Name, ForeColor = Theme.Text, Margin = new Padding(0, 0, 6, 0) });
        top.Controls.Add(new Pill(badgeText, badgeColor) { Margin = new Padding(0, 3, 0, 0) });
        text.Controls.Add(top, 0, 0);
        text.Controls.Add(new Label
        {
            Text = string.Join(" · ", details), AutoSize = false, Dock = DockStyle.Fill, ForeColor = Theme.Secondary,
            AutoEllipsis = true, Margin = new Padding(0, 2, 8, 0),
        }, 0, 1);

        var actions = new FlowLayoutPanel { Dock = DockStyle.Right, AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Padding = new Padding(0, 9, 0, 0) };
        void Button(string title, Action action, bool prominent = false, bool enabled = true)
        {
            var b = new Button { Text = title, Margin = new Padding(6, 0, 0, 0), Enabled = enabled && model.Busy == null };
            Theme.StyleButton(b, prominent && b.Enabled);
            b.Click += (_, _) => action();
            actions.Controls.Add(b);
        }
        switch (status.Place)
        {
            case Place.Main:
                Button(model.Snapshot?.Main.Running == true ? "Show Claude" : "Open Claude", model.OpenMain);
                break;
            case Place.Window:
                Button("Show", () => model.ShowWindow(status));
                Button("Close Window", () => model.CloseWindow(status));
                break;
            case Place.Saved:
                Button("Open Side by Side", () => model.OpenWindow(status), prominent: true, enabled: !expired);
                Button("Switch", () => model.SwitchTo(status));
                break;
        }
        var more = new Button { Text = "···", Margin = new Padding(6, 0, 0, 0), Enabled = model.Busy == null };
        Theme.StyleButton(more);
        var menu = new ContextMenuStrip();
        if (status.Place is Place.Saved or Place.Window)
        {
            menu.Items.Add("Switch Main Claude to This Account", null, (_, _) => model.SwitchTo(status));
            menu.Items.Add(new ToolStripSeparator());
        }
        menu.Items.Add("Rename…", null, (_, _) => model.Rename(status));
        menu.Items.Add(new ToolStripMenuItem("Show Folder in File Explorer", null, (_, _) => model.ShowFolder(status)) { Enabled = Directory.Exists(status.Folder) });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Remove…", null, (_, _) => model.Remove(status)) { Enabled = status.Place is not (Place.Main or Place.Window) });
        more.Click += (_, _) => menu.Show(more, new Point(0, more.Height));
        actions.Controls.Add(more);

        Controls.Add(text);
        Controls.Add(actions);
    }

    static string Ago(DateTime when)
    {
        var span = DateTime.Now - when;
        if (span.TotalMinutes < 1) return "just now";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} min ago";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} h ago";
        if (span.TotalDays < 2) return "yesterday";
        return $"{(int)span.TotalDays} days ago";
    }

    protected override void OnPaintBackground(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Window);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), 10))
        using (var fill = new SolidBrush(Theme.Card))
        using (var pen = new Pen(highlight.HasValue ? Theme.Tint(highlight.Value, 0.75) : Theme.Border, highlight.HasValue ? 1.5f : 1f))
        {
            g.FillPath(fill, path);
            g.DrawPath(pen, path);
        }
        // A round badge with the account's initials, in a colour that stays the same for a name.
        var words = status.Account.Name.Split(c => !char.IsLetterOrDigit(c));
        string initials = string.Concat(new[] { words.FirstOrDefault(), words.Length > 1 ? words[^1] : null }
            .Where(w => !string.IsNullOrEmpty(w)).Select(w => char.ToUpperInvariant(w![0])));
        int index = status.Account.Name.Aggregate(0, (acc, c) => (acc + c) % 997) % AvatarColors.Length;
        var circle = new Rectangle(16, (Height - 42) / 2, 42, 42);
        using (var brush = new LinearGradientBrush(circle, ControlPaint.Light(AvatarColors[index], 0.2f), AvatarColors[index], 90f))
            g.FillEllipse(brush, circle);
        TextRenderer.DrawText(g, initials, new Font("Segoe UI Semibold", 11.5f), circle, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}

static class StringSplit
{
    public static string[] Split(this string s, Func<char, bool> separator)
    {
        var parts = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (char c in s)
        {
            if (separator(c)) { if (current.Length > 0) { parts.Add(current.ToString()); current.Clear(); } }
            else current.Append(c);
        }
        if (current.Length > 0) parts.Add(current.ToString());
        return parts.ToArray();
    }
}

/// <summary>A small rounded label.</summary>
sealed class Pill : Control
{
    readonly Color color;

    public Pill(string text, Color color)
    {
        this.color = color;
        Text = text;
        Font = Theme.Badge;
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        BackColor = Color.Transparent;
        var size = TextRenderer.MeasureText(text, Font);
        Size = new Size(size.Width + 14, size.Height + 4);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = Theme.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), (Height - 1) / 2);
        using var brush = new SolidBrush(Theme.Tint(color, 0.15));
        e.Graphics.FillPath(brush, path);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
}
