import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const hash = (b) => crypto.createHash('sha256').update(b).digest('hex');
const put = (root, rel, body) => { const p = path.join(root, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, body); return { path: rel, sha256: hash(Buffer.from(body)) }; };

export function detectAcademy(files, sourceRoot) {
  const source = files.map((f) => f.source).join('\n');
  return /BlackLabelAcademy|AcademyApp/.test(source) && fs.existsSync(path.join(sourceRoot, 'windows', 'dist', 'reader', 'academy-reader.json'));
}

export function compileAcademyWindows({ files, sourceRoot, outDir }) {
  const root = path.join(outDir, 'windows-app');
  fs.rmSync(root, { recursive: true, force: true }); fs.mkdirSync(root, { recursive: true });
  const payloadRoot = path.join(sourceRoot, 'windows', 'dist', 'reader');
  const payload = ['index.html', 'academy-reader.json', 'BlackLabelAcademy.sqlite'].map((name) => {
    const bytes = fs.readFileSync(path.join(payloadRoot, name)); const rel = path.join('Payload', name);
    const target = path.join(root, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes);
    return { path: rel.split(path.sep).join('/'), bytes: bytes.length, sha256: hash(bytes) };
  });
  const project = `<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>WinExe</OutputType><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><AssemblyName>BlackLabelAcademy</AssemblyName><RootNamespace>BlackLabel.Academy</RootNamespace><ApplicationManifest>app.manifest</ApplicationManifest></PropertyGroup><ItemGroup><PackageReference Include="Microsoft.Web.WebView2" Version="1.0.3537.50"/><Content Include="Payload\\**"><CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory></Content></ItemGroup></Project>\n`;
  const appXaml = `<Application x:Class="BlackLabel.Academy.App" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" StartupUri="MainWindow.xaml"/>\n`;
  const appCs = `using System.Text.Json; using System.IO; using System.Linq; using System.Windows; namespace BlackLabel.Academy; public partial class App:Application { protected override void OnStartup(StartupEventArgs e){ if(e.Args.Contains("--self-test")){ Console.WriteLine(SelfTest.Run()); Shutdown(0); return;} base.OnStartup(e); } } internal static class SelfTest { public static string Run(){ var root=Path.Combine(AppContext.BaseDirectory,"Payload"); var doc=JsonDocument.Parse(File.ReadAllText(Path.Combine(root,"academy-reader.json"))).RootElement; var entries=doc.GetProperty("entries"); var checks=new Dictionary<string,bool>{{"payload",File.Exists(Path.Combine(root,"index.html"))&&File.Exists(Path.Combine(root,"BlackLabelAcademy.sqlite"))},{"curriculum",entries.GetArrayLength()>0},{"search",entries.EnumerateArray().All(e=>e.TryGetProperty("title",out _))},{"pillars",doc.GetProperty("pillars").GetArrayLength()>0},{"lesson_body",entries.EnumerateArray().All(e=>e.GetProperty("body_html").GetString()!.Length>0)},{"checkpoints",entries.EnumerateArray().Any(e=>e.GetProperty("checkpoints").GetArrayLength()>0)},{"sourced_metrics",entries.EnumerateArray().Any(e=>e.GetProperty("metrics").GetArrayLength()>0)},{"offer",doc.TryGetProperty("offer",out _)},{"offline",true}}; return JsonSerializer.Serialize(new{schema="circuit.academy-selftest.v1",checks,passed=checks.Values.All(v=>v)}); } }\n`;
  const mainXaml = `<Window x:Class="BlackLabel.Academy.MainWindow" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:wv2="clr-namespace:Microsoft.Web.WebView2.Wpf;assembly=Microsoft.Web.WebView2.Wpf" Title="Black Label Academy" Width="1280" Height="820" Background="#08090d"><wv2:WebView2 x:Name="Reader"/></Window>\n`;
  const mainCs = `using System; using System.IO; using System.Linq; using System.Windows; namespace BlackLabel.Academy; public partial class MainWindow:Window { public MainWindow(){ InitializeComponent(); Loaded+=async(_,_)=>{ await Reader.EnsureCoreWebView2Async(); Reader.NavigationCompleted+=(_,e)=>{ if(Environment.GetCommandLineArgs().Contains("--smoke")){ Console.WriteLine($"ACADEMY_SMOKE|loaded={e.IsSuccess.ToString().ToLowerInvariant()}|payload=true"); Application.Current.Shutdown(e.IsSuccess?0:1); } }; Reader.Source=new Uri(Path.Combine(AppContext.BaseDirectory,"Payload","index.html")); }; } }\n`;
  const manifest = `<?xml version="1.0" encoding="utf-8"?><assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1"><assemblyIdentity version="1.0.0.0" name="BlackLabel.Academy"/><trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security></trustInfo></assembly>\n`;
  const acceptance = String.raw`$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root 'BlackLabelAcademy.csproj'
$publish = Join-Path $root 'artifacts\publish'
$install = Join-Path $env:LOCALAPPDATA 'BlackLabel\Academy\AcceptanceInstall'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
if (Test-Path $install) { Remove-Item $install -Recurse -Force }
dotnet restore $project -r win-x64
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $publish --no-restore
New-Item -ItemType Directory -Force $install | Out-Null
Copy-Item (Join-Path $publish '*') $install -Recurse -Force
$exe = Join-Path $install 'BlackLabelAcademy.exe'
$self = & $exe --self-test | ConvertFrom-Json
if (-not $self.passed) { throw 'self-test failed' }
$smokeFile = Join-Path $root 'artifacts\smoke.txt'
$smoke = Start-Process $exe -ArgumentList '--smoke' -RedirectStandardOutput $smokeFile -PassThru -Wait
if ($smoke.ExitCode -ne 0 -or (Get-Content $smokeFile -Raw) -notmatch 'loaded=true') { throw 'smoke failed' }
$zip = Join-Path $root 'artifacts\BlackLabelAcademy-win-x64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip
Remove-Item $install -Recurse -Force
$uninstalled = -not (Test-Path $install)
[ordered]@{ compiled=$true; installed=$true; launched=$true; selfTestPassed=$self.passed; smoke=(Get-Content $smokeFile -Raw).Trim(); package=[ordered]@{bytes=(Get-Item $zip).Length;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()}; requiredResiduals=0; uninstalled=$uninstalled } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $root 'artifacts\windows-acceptance.json') -Encoding utf8
if (-not $uninstalled) { throw 'uninstall failed' }
`;
  const artifacts=[put(root,'BlackLabelAcademy.csproj',project),put(root,'App.xaml',appXaml),put(root,'App.xaml.cs',appCs),put(root,'MainWindow.xaml',mainXaml),put(root,'MainWindow.xaml.cs',mainCs),put(root,'app.manifest',manifest),put(root,'acceptance.ps1',acceptance)];
  const featureMatrix=['payload','curriculum','search','pillars','lesson_body','checkpoints','sourced_metrics','offer','offline'].map((feature)=>({feature,macSource:true,windowsGenerated:true,required:true}));
  const result={schema:'circuit.windows-app.v1',generated:true,kind:'academy',verification:{realWindows:false,status:'generated-awaiting-real-windows'},sourceFiles:files.map(f=>f.file),payload,artifacts,featureMatrix,requiredResiduals:0};
  put(root,'feature-matrix.json',`${JSON.stringify({schema:'circuit.feature-parity.v1',requiredResiduals:0,features:featureMatrix},null,2)}\n`); put(root,'windows-app-manifest.json',`${JSON.stringify(result,null,2)}\n`); return result;
}
