using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace BlackLabel.LiveWallpaper;

public sealed class WallpaperWindow : Window
{
    private readonly WallpaperSurface surface;
    public bool ImageLoaded => surface.ImageLoaded;
    public bool IsPaused => surface.IsPaused;

    public WallpaperWindow(bool letterbox, bool paused)
    {
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false;
        AllowsTransparency = false; Background = Brushes.Black; Topmost = false; Focusable = false;
        surface = new WallpaperSurface(letterbox, paused); Content = surface;
        SourceInitialized += (_, _) => Native.MakePassive(new WindowInteropHelper(this).Handle);
    }
    public void SetPaused(bool value) => surface.SetPaused(value);
    public void SetLetterbox(bool value) => surface.SetLetterbox(value);
    public void AttachToDesktop() => Native.AttachToDesktop(new WindowInteropHelper(this).Handle);
}

public sealed class WallpaperSurface : FrameworkElement
{
    private static readonly Uri AssetUri = new("pack://application:,,,/Assets/wallpaper.png", UriKind.Absolute);
    private readonly BitmapImage image = new(AssetUri);
    private readonly DispatcherTimer timer;
    private bool letterbox;
    private bool paused;
    private readonly DateTime started = DateTime.UtcNow;
    public bool ImageLoaded => image.PixelWidth == 5504 && image.PixelHeight == 3072;
    public bool IsPaused => paused;
    public static bool AssetExists => Application.GetResourceStream(AssetUri) != null;
    public static string AssetSha256 { get { using var stream = Application.GetResourceStream(AssetUri)!.Stream; return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); } }

    public WallpaperSurface(bool letterbox, bool paused)
    {
        this.letterbox = letterbox; this.paused = paused;
        timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromSeconds(1.0 / 30.0) };
        timer.Tick += (_, _) => { if (!this.paused && IsVisible) InvalidateVisual(); };
        timer.Start();
    }
    public static Stretch StretchFor(bool letterbox) => letterbox ? Stretch.Uniform : Stretch.UniformToFill;
    public static (double Charge, double Burst) FrameAt(double t) {
        var phase = t % 8.0; var charge = phase < 3 ? phase / 3 : phase < 3.3 ? 1 : phase < 3.9 ? Math.Max(0, 1 - (phase - 3.3) / .6) : 0;
        var burst = phase >= 3.3 && phase < 5 ? (phase - 3.3) / 1.7 : -1; return (charge, burst);
    }
    public void SetPaused(bool value) { paused = value; InvalidateVisual(); }
    public void SetLetterbox(bool value) { letterbox = value; InvalidateVisual(); }

    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); var bounds = new Rect(0, 0, ActualWidth, ActualHeight); dc.DrawRectangle(Brushes.Black, null, bounds);
        var fit = Fit(bounds.Size, image.PixelWidth / (double)image.PixelHeight, !letterbox);
        dc.DrawImage(image, fit);
        var t = (DateTime.UtcNow - started).TotalSeconds; var frame = FrameAt(t);
        var gold = Color.FromRgb(251, 219, 133); var center = new Point(fit.X + fit.Width * .5, fit.Y + fit.Height * .33);
        for (var i = 0; i < 3; i++) { var r = fit.Height * (.045 + i * .022 + .006 * Math.Sin(t * (1 + i * .1))); dc.DrawEllipse(null, new Pen(new SolidColorBrush(Color.FromArgb((byte)(110 + frame.Charge * 100), gold.R, gold.G, gold.B)), Math.Max(1, fit.Height * .0015)), center, r, r); }
        var labels = new[] { "LEADS", "REAL ESTATE", "MARKETING", "TRADING", "SOVEREIGN", "VIGIL" };
        for (var i = 0; i < labels.Length; i++) { var x = fit.X + fit.Width * (.08 + i * .145); var y = fit.Y + fit.Height * .89; var text = new FormattedText(labels[i], System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI Semibold"), Math.Max(10, fit.Height * .015), new SolidColorBrush(gold), 1.0); dc.DrawText(text, new Point(x, y)); }
        if (frame.Burst >= 0) { var radius = Math.Sqrt(ActualWidth * ActualWidth + ActualHeight * ActualHeight) * .62 * frame.Burst; dc.DrawEllipse(null, new Pen(new SolidColorBrush(Color.FromArgb((byte)(180 * (1 - frame.Burst)), gold.R, gold.G, gold.B)), Math.Max(1, 12 * (1 - frame.Burst))), center, radius, radius); }
    }

    private static Rect Fit(System.Windows.Size screen, double aspect, bool fill)
    {
        var screenAspect = screen.Width / Math.Max(screen.Height, 1); var matchWidth = fill ? screenAspect >= aspect : screenAspect <= aspect;
        if (matchWidth) { var h = screen.Width / aspect; return new Rect(0, (screen.Height - h) / 2, screen.Width, h); }
        var w = screen.Height * aspect; return new Rect((screen.Width - w) / 2, 0, w, screen.Height);
    }
}

internal static class Native
{
    private const int GWL_EXSTYLE = -20, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string? cls, string? name);
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? cls, string? title);
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    public static void MakePassive(IntPtr hwnd) => SetWindowLong(hwnd, GWL_EXSTYLE, GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    public static void AttachToDesktop(IntPtr hwnd) {
        var progman = FindWindow("Progman", null); SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, 0, 1000, out _); IntPtr worker = IntPtr.Zero;
        EnumWindows((top, _) => { if (FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero) worker = FindWindowEx(IntPtr.Zero, top, "WorkerW", null); return true; }, IntPtr.Zero);
        SetParent(hwnd, worker != IntPtr.Zero ? worker : progman);
    }
}
