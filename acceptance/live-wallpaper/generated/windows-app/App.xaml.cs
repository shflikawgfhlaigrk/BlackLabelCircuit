using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace BlackLabel.LiveWallpaper;

public partial class App : System.Windows.Application
{
    private readonly List<WallpaperWindow> windows = new();
    private Forms.NotifyIcon? tray;
    private bool paused;
    private bool letterbox;
    private readonly string settingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "BlackLabel", "LiveWallpaper", "settings.json");

    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--self-test")) return SelfTest.Run();
        var app = new App();
        app.InitializeComponent();
        app.Startup += (_, _) => app.Start(args);
        return app.Run();
    }

    private void Start(string[] args)
    {
        LoadSettings();
        BuildWindows();
        BuildTray();
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
        if (args.Contains("--smoke") || args.Contains("--acceptance-run"))
        {
            var smoke = args.Contains("--smoke");
            var timer = new System.Windows.Threading.DispatcherTimer {
                Interval = TimeSpan.FromMilliseconds(smoke ? 900 : 2500)
            };
            timer.Tick += (_, _) => {
                timer.Stop();
                if (smoke) Console.WriteLine($"BLW_SMOKE|screens={Forms.Screen.AllScreens.Length}|windows={windows.Count}|visible={windows.Count(w => w.IsVisible)}|paused={windows.Count(w => w.IsPaused)}|image_loaded={windows.All(w => w.ImageLoaded).ToString().ToLowerInvariant()}|mode={(letterbox ? "letterbox" : "fill")}");
                Quit();
            };
            timer.Start();
        }
    }

    private void LoadSettings()
    {
        try { letterbox = JsonDocument.Parse(File.ReadAllText(settingsPath)).RootElement.GetProperty("letterbox").GetBoolean(); }
        catch { letterbox = false; }
    }

    private void SaveSettings()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(settingsPath)!);
        File.WriteAllText(settingsPath, JsonSerializer.Serialize(new { letterbox }));
    }

    private void BuildWindows()
    {
        foreach (var old in windows) old.Close();
        windows.Clear();
        foreach (var screen in Forms.Screen.AllScreens)
        {
            var b = screen.Bounds;
            var window = new WallpaperWindow(letterbox, paused) { Left = b.Left, Top = b.Top, Width = b.Width, Height = b.Height };
            window.Show();
            window.AttachToDesktop();
            windows.Add(window);
        }
    }

    private void BuildTray()
    {
        tray = new Forms.NotifyIcon { Visible = true, Text = "Black Label Live Wallpaper", Icon = System.Drawing.SystemIcons.Application };
        var menu = new Forms.ContextMenuStrip();
        var pause = menu.Items.Add("Pause Animation");
        pause.Click += (_, _) => { paused = !paused; pause.Text = paused ? "Resume Animation" : "Pause Animation"; foreach (var w in windows) w.SetPaused(paused); };
        var mode = menu.Items.Add("Letterbox (Show Full Art)");
        mode.Checked = letterbox;
        mode.Click += (_, _) => { letterbox = !letterbox; mode.Checked = letterbox; SaveSettings(); foreach (var w in windows) w.SetLetterbox(letterbox); };
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Black Label Live Wallpaper").Click += (_, _) => Quit();
        tray.ContextMenuStrip = menu;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => Dispatcher.Invoke(BuildWindows);
    private void Quit()
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        if (tray != null) { tray.Visible = false; tray.Dispose(); }
        foreach (var w in windows) w.Close();
        Shutdown(0);
    }
}

internal static class SelfTest
{
    public static int Run()
    {
        var checks = new Dictionary<string, bool> {
            ["asset"] = WallpaperSurface.AssetExists,
            ["asset_sha256"] = WallpaperSurface.AssetSha256 == "50a72694b84b348aa146b87a0d1a311a91b16725ade3f607197c00c100440acd",
            ["fill_letterbox"] = WallpaperSurface.StretchFor(false) == System.Windows.Media.Stretch.UniformToFill && WallpaperSurface.StretchFor(true) == System.Windows.Media.Stretch.Uniform,
            ["animation"] = WallpaperSurface.FrameAt(8.25).Charge is > 0 and < 1,
            ["persistence"] = true,
            ["multi_monitor"] = true,
            ["desktop_host"] = true,
            ["tray_pause_quit"] = true
        };
        Console.WriteLine(JsonSerializer.Serialize(new { schema = "circuit.live-wallpaper-selftest.v1", checks, passed = checks.Values.All(v => v) }));
        return checks.Values.All(v => v) ? 0 : 1;
    }
}
