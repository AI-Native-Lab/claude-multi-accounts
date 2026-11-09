using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace ClaudeMultiAccounts.App;

/// <summary>Colours and fonts, light or dark like Windows' app setting.</summary>
static class Theme
{
    public static readonly bool Dark = ReadDark();

    public static Color Window => Dark ? Color.FromArgb(32, 32, 32) : Color.FromArgb(243, 243, 243);
    public static Color Card => Dark ? Color.FromArgb(43, 43, 43) : Color.White;
    public static Color Border => Dark ? Color.FromArgb(60, 60, 60) : Color.FromArgb(225, 225, 225);
    public static Color Text => Dark ? Color.FromArgb(240, 240, 240) : Color.FromArgb(26, 26, 26);
    public static Color Secondary => Dark ? Color.FromArgb(170, 170, 170) : Color.FromArgb(96, 96, 96);
    public static readonly Color Accent = Color.FromArgb(217, 119, 87);   // Claude's clay
    public static readonly Color Blue = Color.FromArgb(0, 120, 212);
    public static readonly Color Green = Color.FromArgb(16, 137, 62);
    public static readonly Color Orange = Color.FromArgb(202, 80, 16);
    public static readonly Color Gray = Color.FromArgb(118, 118, 118);

    public static readonly Font Body = new("Segoe UI", 9.75f);
    public static readonly Font Small = new("Segoe UI", 8.75f);
    public static readonly Font Badge = new("Segoe UI Semibold", 8f);
    public static readonly Font Heading = new("Segoe UI Semibold", 11.5f);
    public static readonly Font Title = new("Segoe UI Semibold", 15f);
    public static readonly Font Name = new("Segoe UI Semibold", 11f);

    public static Color Tint(Color c, double amount) =>
        Color.FromArgb((int)(Card.R + (c.R - Card.R) * amount), (int)(Card.G + (c.G - Card.G) * amount), (int)(Card.B + (c.B - Card.B) * amount));

    static bool ReadDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    public static GraphicsPath Rounded(Rectangle r, int radius)
    {
        int d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    public static Icon AppIcon()
    {
        using var stream = typeof(Theme).Assembly.GetManifestResourceStream("AppIcon.ico");
        return stream != null ? new Icon(stream) : SystemIcons.Application;
    }

    public static void StyleButton(Button b, bool prominent = false)
    {
        b.FlatStyle = FlatStyle.Flat;
        b.AutoSize = true;
        b.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        b.Padding = new Padding(8, 2, 8, 2);
        b.MinimumSize = new Size(0, 30);
        b.Cursor = Cursors.Hand;
        b.Font = Body;
        b.FlatAppearance.BorderColor = prominent ? Accent : Border;
        b.BackColor = prominent ? Accent : Card;
        b.ForeColor = prominent ? Color.White : Text;
        b.FlatAppearance.MouseOverBackColor = prominent ? ControlPaint.Dark(Accent, 0.05f) : Tint(Text, 0.06);
        b.UseVisualStyleBackColor = false;
    }
}
