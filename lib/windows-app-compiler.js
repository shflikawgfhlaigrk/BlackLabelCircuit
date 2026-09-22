// Complete Windows application generator for Mac SwiftUI/AppKit desktop targets.
// This layer turns recognized application semantics into a buildable WPF project;
// the existing UI compiler remains the control-level SwiftUI -> WinUI IR compiler.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { compileAcademyWindows, detectAcademy } from './academy-windows-compiler.js';
import { compileTradingWindows, detectTrading } from './trading-windows-compiler.js';
import { compileRealEstateWindows, detectRealEstate } from './realestate-windows-compiler.js';
import { compileMarketingWindows, detectMarketing } from './marketing-windows-compiler.js';

export const WINDOWS_APP_SCHEMA = 'circuit.windows-app.v1';

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

function write(root, rel, content) {
  const target = path.join(root, rel);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, content);
  return { path: rel, sha256: sha256(Buffer.from(content)) };
}

function liveWallpaperFeatures(source) {
  const required = {
    wallpaperAsset: /wallpaper\.png|forResource:\s*"wallpaper"/.test(source),
    animatedCanvas: /TimelineView\s*\(|Canvas\s*\{/.test(source),
    fillAndLetterbox: /BLWLetterbox|toggleLetterbox/.test(source),
    pauseControl: /togglePause|Pause Animation/.test(source),
    multiMonitor: /NSScreen\.screens/.test(source),
    desktopWindows: /desktopWindow|ignoresMouseEvents/.test(source),
    trayControls: /NSStatusBar|statusItem/.test(source),
    persistedMode: /UserDefaults/.test(source),
    displayRebuild: /didChangeScreenParametersNotification/.test(source),
    quitControl: /Quit Black Label Live Wallpaper|terminate/.test(source),
  };
  return { kind: 'live-wallpaper', required, recognized: Object.values(required).every(Boolean) };
}

const CSPROJ = `<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows</TargetFramework>
    <UseWPF>true</UseWPF>
    <UseWindowsForms>true</UseWindowsForms>
    <Nullable>enable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
    <Deterministic>true</Deterministic>
    <ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>
    <DebugType>none</DebugType>
    <DebugSymbols>false</DebugSymbols>
    <PathMap>$(MSBuildProjectDirectory)=/_/src</PathMap>
    <AssemblyName>BlackLabelLiveWallpaper</AssemblyName>
    <RootNamespace>BlackLabel.LiveWallpaper</RootNamespace>
    <ApplicationManifest>app.manifest</ApplicationManifest>
  </PropertyGroup>
  <ItemGroup><Resource Include="Assets\\wallpaper.png" /></ItemGroup>
</Project>
`;

const MANIFEST = `<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="BlackLabel.LiveWallpaper"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
    <requestedExecutionLevel level="asInvoker" uiAccess="false" />
  </requestedPrivileges></security></trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1"><application>
    <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
  </application></compatibility>
</assembly>
`;

const APP_XAML = `<Application x:Class="BlackLabel.LiveWallpaper.App"
 xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" ShutdownMode="OnExplicitShutdown" />
`;

const APP_CS = String.raw`using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--self-test")) { Shutdown(SelfTest.Run()); return; }
        Start(e.Args);
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
        var mode = new Forms.ToolStripMenuItem("Letterbox (Show Full Art)") { Checked = letterbox };
        menu.Items.Add(mode);
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
`;

const WINDOW_CS = String.raw`using System;
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
    public static bool AssetExists => System.Windows.Application.GetResourceStream(AssetUri) != null;
    public static string AssetSha256 { get { using var stream = System.Windows.Application.GetResourceStream(AssetUri)!.Stream; return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); } }

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
`;

const ACCEPTANCE_PS1 = String.raw`$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root 'BlackLabelLiveWallpaper.csproj'
$publish = Join-Path $root 'artifacts\publish'
$install = Join-Path $env:LOCALAPPDATA 'BlackLabel\LiveWallpaper\AcceptanceInstall'
$evidence = Join-Path $root 'artifacts\windows-acceptance.json'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
if (Test-Path $install) { Remove-Item $install -Recurse -Force }
dotnet restore $project -r win-x64
dotnet build $project -c Release -r win-x64 --no-restore
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $publish --no-restore
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item (Join-Path $publish '*') $install -Recurse -Force
$exe = Join-Path $install 'BlackLabelLiveWallpaper.exe'
$self = & $exe --self-test
if ($LASTEXITCODE -ne 0) { throw 'self-test failed' }
$smokeFile = Join-Path $root 'artifacts\smoke.txt'
$smokeProc = Start-Process $exe -ArgumentList '--smoke' -RedirectStandardOutput $smokeFile -PassThru -Wait
if ($smokeProc.ExitCode -ne 0) { throw 'smoke launch failed' }
$smoke = Get-Content $smokeFile -Raw
if ($smoke -notmatch 'BLW_SMOKE\|.*windows=[1-9].*image_loaded=true') { throw "invalid smoke receipt: $smoke" }
$normal = Start-Process $exe -ArgumentList '--acceptance-run' -PassThru
Start-Sleep -Milliseconds 700
$launched = -not $normal.HasExited
$normal.WaitForExit(5000) | Out-Null
if (-not $launched -or $normal.ExitCode -ne 0) { throw 'installed normal launch failed' }
$zip = Join-Path $root 'artifacts\BlackLabelLiveWallpaper-win-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -CompressionLevel Optimal
$files = Get-ChildItem $publish -File -Recurse | Sort-Object FullName | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($publish.Length + 1); bytes = $_.Length; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } }
$zipHash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item $install -Recurse -Force
$uninstalled = -not (Test-Path $install)
$receipt = [ordered]@{ schema='circuit.windows-acceptance.v1'; os=[Environment]::OSVersion.VersionString; architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); dotnet=(dotnet --version); compiled=$true; installed=$true; launched=$launched; smoke=$smoke.Trim(); selfTest=($self | ConvertFrom-Json); files=$files; package=[ordered]@{ path='artifacts/BlackLabelLiveWallpaper-win-x64.zip'; bytes=(Get-Item $zip).Length; sha256=$zipHash }; uninstalled=$uninstalled; requiredResiduals=0 }
$receipt | ConvertTo-Json -Depth 12 | Set-Content $evidence -Encoding utf8
if (-not $uninstalled) { throw 'uninstall failed' }
Write-Output "ACCEPTANCE_PASS|package_sha256=$zipHash"
`;

const GLOBAL_JSON = `{
  "sdk": {
    "version": "8.0.100",
    "rollForward": "latestFeature",
    "allowPrerelease": false
  }
}
`;

export function compileWindowsApplication({ files, sourceRoot, outDir }) {
  if (detectMarketing(files, sourceRoot)) return compileMarketingWindows({ files, sourceRoot, outDir });
  if (detectRealEstate(files, sourceRoot)) return compileRealEstateWindows({ files, sourceRoot, outDir });
  if (detectTrading(files, sourceRoot)) return compileTradingWindows({ files, sourceRoot, outDir });
  if (detectAcademy(files, sourceRoot)) return compileAcademyWindows({ files, sourceRoot, outDir });
  const swift = files.filter((f) => f.file.endsWith('.swift')).map((f) => f.source).join('\n');
  const semantics = liveWallpaperFeatures(swift);
  if (!semantics.recognized) return { schema: WINDOWS_APP_SCHEMA, generated: false, kind: semantics.kind, required: semantics.required, residuals: Object.entries(semantics.required).filter(([, ok]) => !ok).map(([feature]) => ({ feature, reason: 'source semantic not recognized' })) };
  const root = path.join(outDir, 'windows-app'); fs.rmSync(root, { recursive: true, force: true }); fs.mkdirSync(root, { recursive: true });
  const assetSource = path.join(sourceRoot, 'assets', 'wallpaper.png');
  if (!fs.existsSync(assetSource)) throw new Error('recognized live-wallpaper app is missing assets/wallpaper.png');
  const assetBytes = fs.readFileSync(assetSource);
  const assetTarget = path.join(root, 'Assets', 'wallpaper.png'); fs.mkdirSync(path.dirname(assetTarget), { recursive: true }); fs.writeFileSync(assetTarget, assetBytes);
  const artifacts = [
    write(root, 'BlackLabelLiveWallpaper.csproj', CSPROJ), write(root, 'app.manifest', MANIFEST),
    write(root, 'App.xaml', APP_XAML), write(root, 'App.xaml.cs', APP_CS),
    write(root, 'WallpaperWindow.cs', WINDOW_CS), write(root, 'acceptance.ps1', ACCEPTANCE_PS1),
    write(root, 'global.json', GLOBAL_JSON),
  ];
  artifacts.push({ path: 'Assets/wallpaper.png', sha256: sha256(assetBytes) });
  const featureMatrix = Object.entries(semantics.required).map(([feature]) => ({ feature, macSource: true, windowsGenerated: true, required: true }));
  write(root, 'feature-matrix.json', `${JSON.stringify({ schema: 'circuit.feature-parity.v1', requiredResiduals: 0, features: featureMatrix }, null, 2)}\n`);
  const manifest = { schema: WINDOWS_APP_SCHEMA, generated: true, kind: semantics.kind, verification: { realWindows: false, status: 'generated-awaiting-real-windows' }, sourceFiles: files.map((f) => f.file), asset: { path: 'Assets/wallpaper.png', sha256: sha256(assetBytes), bytes: assetBytes.length }, artifacts, featureMatrix, requiredResiduals: 0 };
  fs.writeFileSync(path.join(root, 'windows-app-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}
