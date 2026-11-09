namespace ClaudeMultiAccounts.App;

/// <summary>Questions and messages, as Windows task dialogs.</summary>
static class Prompt
{
    public static IWin32Window? Owner;

    public static bool Confirm(string title, string message, string button)
    {
        bool _ = false;
        return Confirm(title, message, button, false, ref _);
    }

    public static bool Confirm(string title, string message, string button, bool suppressible, ref bool dontAskAgain)
    {
        var ok = new TaskDialogButton(button);
        var page = new TaskDialogPage
        {
            Caption = "Claude Multi-Accounts",
            Heading = title,
            Text = message,
            Buttons = { ok, TaskDialogButton.Cancel },
            DefaultButton = ok,
            Verification = suppressible ? new TaskDialogVerificationCheckBox("Don't ask again") : null,
        };
        var result = Show(page);
        if (suppressible) dontAskAgain = page.Verification!.Checked;
        return result == ok;
    }

    public static void Info(string title, string message) =>
        Show(new TaskDialogPage { Caption = "Claude Multi-Accounts", Heading = title, Text = message, Icon = TaskDialogIcon.Information });

    public static void Error(Exception error) =>
        Show(new TaskDialogPage
        {
            Caption = "Claude Multi-Accounts",
            Heading = error is Core.SwapException ? "That didn't work" : "Something went wrong",
            Text = error.Message,
            Icon = TaskDialogIcon.Warning,
        });

    static TaskDialogButton Show(TaskDialogPage page) =>
        Owner is Form { Visible: true } form ? TaskDialog.ShowDialog(form, page) : TaskDialog.ShowDialog(page);

    /// <summary>Asks for a line of text. Null when cancelled.</summary>
    public static string? Text(string title, string message, string placeholder, string button = "OK",
                               string initial = "", bool allowEmpty = false)
    {
        using var form = new Form
        {
            Text = "Claude Multi-Accounts",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = Owner is Form { Visible: true } ? FormStartPosition.CenterParent : FormStartPosition.CenterScreen,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = Owner is not Form { Visible: true },
            AutoScaleMode = AutoScaleMode.Dpi,
            Font = Theme.Body,
            BackColor = Theme.Window,
            ClientSize = new Size(460, 10),
            Padding = new Padding(20),
        };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
        var heading = new Label { Text = title, Font = Theme.Heading, AutoSize = true, MaximumSize = new Size(420, 0), Margin = new Padding(0, 0, 0, 8) };
        var text = new Label { Text = message, AutoSize = true, MaximumSize = new Size(420, 0), ForeColor = Theme.Secondary, Margin = new Padding(0, 0, 0, 12) };
        var box = new TextBox { Text = initial, PlaceholderText = placeholder, Width = 420, Margin = new Padding(0, 0, 0, 16) };
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, AutoSize = true, Margin = Padding.Empty };
        var ok = new Button { Text = button, DialogResult = DialogResult.OK, AutoSize = true, MinimumSize = new Size(90, 30) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, AutoSize = true, MinimumSize = new Size(90, 30) };
        buttons.Controls.Add(ok);
        buttons.Controls.Add(cancel);
        layout.Controls.Add(heading);
        layout.Controls.Add(text);
        layout.Controls.Add(box);
        layout.Controls.Add(buttons);
        form.Controls.Add(layout);
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        form.AutoSize = true;
        form.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        void Update() => ok.Enabled = allowEmpty || box.Text.Trim().Length > 0;
        box.TextChanged += (_, _) => Update();
        Update();
        form.Shown += (_, _) => { box.Focus(); box.SelectAll(); };
        var result = Owner is Form { Visible: true } owner ? form.ShowDialog(owner) : form.ShowDialog();
        return result == DialogResult.OK ? box.Text.Trim() : null;
    }
}
