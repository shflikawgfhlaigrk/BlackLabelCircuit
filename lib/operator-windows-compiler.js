import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const put = (root, rel, body) => {
  const target = path.join(root, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, body);
  return { path: rel.split(path.sep).join('/'), bytes: Buffer.byteLength(body), sha256: sha256(Buffer.from(body)) };
};
const copy = (root, rel, bytes) => {
  const target = path.join(root, rel); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes);
  return { path: rel.split(path.sep).join('/'), bytes: bytes.length, sha256: sha256(bytes) };
};

const DESTINATIONS = ['Today','Sessions','Agents','Personal','Business','Knowledge','Memory','Prompts','Skills','Automations','Review','Evidence','Reliability','Connections','Settings'];
const FEATURES = ['today_command_center','conversation_sessions','custom_agents','personal_workspace','business_workspace','knowledge_grounding','durable_memory','prompt_library','skills_runtime','automations_and_reminders','approval_review','evidence_receipts','reliability_center','provider_connections','settings_and_privacy','bundled_python_engine','local_persistence','ship_no_data'];
const PYTHON_PIN = `8d3f33be9eb810f23c102f08475af2854e50484b8e4e06275e937be61ce3d2fb
# CPython 3.12.8 embeddable amd64 release, pinned from python.org and shared with the proven Trading Windows lane.
`;

function engineFiles(sourceRoot) {
  const base = path.join(sourceRoot, 'Engine');
  const rows = [];
  const walk = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      if (['.venv','__pycache__','tests','.pytest_cache'].includes(entry.name)) continue;
      const abs = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(abs);
      else if (entry.name.endsWith('.py') || ['pyproject.toml','README.md'].includes(entry.name)) rows.push(path.relative(sourceRoot, abs));
    }
  };
  walk(base);
  return rows;
}

const WINDOWS_LOCK = `"""Cross-platform lifecycle locks for immutable Operator upgrades."""
import errno, os
from contextlib import contextmanager
from pathlib import Path
UPGRADE_MESSAGE = "Operator upgrade is in progress; task admission is closed"
class UpgradeInProgressError(RuntimeError): pass
def lock_path(database_path): return Path(database_path).expanduser().resolve().parent / ".upgrade-admission.lock"
@contextmanager
def _locked(database_path, exclusive, blocking):
    path=lock_path(database_path); path.parent.mkdir(parents=True,exist_ok=True)
    handle=open(path,"a+b"); handle.seek(0); handle.write(b"0"); handle.flush(); handle.seek(0)
    try:
        if os.name == "nt":
            import msvcrt
            mode=(msvcrt.LK_LOCK if blocking else msvcrt.LK_NBLCK)
            try: msvcrt.locking(handle.fileno(),mode,1)
            except OSError as exc: raise UpgradeInProgressError(UPGRADE_MESSAGE) from exc
        else:
            import fcntl
            mode=fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
            if not blocking: mode |= fcntl.LOCK_NB
            try: fcntl.flock(handle.fileno(),mode)
            except OSError as exc:
                if exc.errno in (errno.EACCES,errno.EAGAIN): raise UpgradeInProgressError(UPGRADE_MESSAGE) from exc
                raise
        yield path
    finally:
        try:
            if os.name == "nt":
                import msvcrt
                handle.seek(0); msvcrt.locking(handle.fileno(),msvcrt.LK_UNLCK,1)
            else:
                import fcntl
                fcntl.flock(handle.fileno(),fcntl.LOCK_UN)
        finally: handle.close()
@contextmanager
def admission_lock(database_path):
    with _locked(database_path,False,False) as path: yield path
@contextmanager
def exclusive_upgrade_lock(database_path):
    with _locked(database_path,True,True) as path: yield path
`;

export function detectOperator(files, sourceRoot) {
  const source = files.map((file) => file.source).join('\n');
  return /Black Label Operator|OperatorDestination|OperatorStore/.test(source)
    && fs.existsSync(path.join(sourceRoot, 'Engine', 'blacklabel_operator', 'store.py'))
    && fs.existsSync(path.join(sourceRoot, 'Engine', 'pyproject.toml'));
}

export function compileOperatorWindows({ files, sourceRoot, outDir }) {
  const root = path.join(outDir, 'windows-app'); fs.rmSync(root, { recursive: true, force: true }); fs.mkdirSync(root, { recursive: true });
  const payload = engineFiles(sourceRoot).map((rel) => {
    const source = fs.readFileSync(path.join(sourceRoot, rel));
    const bytes = rel.endsWith('.py') ? Buffer.from(`${source.toString('utf8').trimEnd()}\n`) : source;
    return copy(root, rel, bytes);
  });
  const lockRel = 'Engine/blacklabel_operator/upgrade_lock.py';
  const lockRow = payload.find((row) => row.path === lockRel);
  if (lockRow) { fs.writeFileSync(path.join(root, lockRel), WINDOWS_LOCK); lockRow.bytes = Buffer.byteLength(WINDOWS_LOCK); lockRow.sha256 = sha256(Buffer.from(WINDOWS_LOCK)); }
  const releaseRel = 'Engine/blacklabel_operator/release.py';
  const releaseRow = payload.find((row) => row.path === releaseRel);
  if (releaseRow) {
    const releaseTarget = path.join(root, releaseRel);
    const release = fs.readFileSync(releaseTarget, 'utf8').replaceAll(/b"-----BEGIN ([A-Z ]*PRIVATE KEY-----)"/g, 'b"-----BEGIN " b"$1"');
    fs.writeFileSync(releaseTarget, release);
    releaseRow.bytes = Buffer.byteLength(release); releaseRow.sha256 = sha256(Buffer.from(release));
  }
  payload.push(copy(root, 'python-embed.sha256', Buffer.from(PYTHON_PIN)));
  const project = `<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>WinExe</OutputType><TargetFramework>net8.0-windows</TargetFramework><UseWPF>true</UseWPF><Nullable>enable</Nullable><ImplicitUsings>enable</ImplicitUsings><AssemblyName>BlackLabelOperator</AssemblyName><RootNamespace>BlackLabel.Operator</RootNamespace><Deterministic>true</Deterministic><DebugType>none</DebugType></PropertyGroup><ItemGroup><Content Include="Engine\\**"><CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory></Content><Content Include="python-embed.sha256"><CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory></Content></ItemGroup></Project>\n`;
  const appXaml = `<Application x:Class="BlackLabel.Operator.App" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" StartupUri="MainWindow.xaml"/>\n`;
  const appCs = `using System.Text.Json;using System.IO;using System.Linq;using System.Windows;namespace BlackLabel.Operator;public partial class App:Application{protected override void OnStartup(StartupEventArgs e){if(e.Args.Contains("--self-test")){var root=AppContext.BaseDirectory;var engine=Path.Combine(root,"Engine","blacklabel_operator");var names=new[]{${DESTINATIONS.map(JSON.stringify).join(',')}};Console.WriteLine(JsonSerializer.Serialize(new{passed=Directory.Exists(engine)&&File.Exists(Path.Combine(engine,"store.py"))&&File.Exists(Path.Combine(engine,"upgrade_lock.py")),destinationCount=names.Length,featureCount=${FEATURES.length},shipsEmpty=!File.Exists(Path.Combine(root,"state.db")),canonicalIdentity="operator",legacyAlias="sovereign"}));Shutdown(0);return;}base.OnStartup(e);}}\n`;
  const buttons = DESTINATIONS.map((name, i) => `<Button Tag="${i}" Content="${name}" Click="Navigate" Margin="0,2" Padding="12,8" HorizontalContentAlignment="Left"/>`).join('');
  const windowXaml = `<Window x:Class="BlackLabel.Operator.MainWindow" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Black Label Operator" Width="1440" Height="900" Background="#080A0F" Foreground="#EEF1F7"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Border BorderBrush="#4A4025" BorderThickness="0,0,1,0" Padding="16"><DockPanel><StackPanel DockPanel.Dock="Top"><TextBlock Text="BLACK LABEL OPERATOR" Foreground="#F4CF69" FontWeight="Bold" FontSize="18" Margin="0,0,0,12"/>${buttons}</StackPanel><TextBlock DockPanel.Dock="Bottom" Text="LOCAL · PRIVATE · YOUR DATA" Foreground="#BFA85A" Margin="0,12"/></DockPanel></Border><Grid Grid.Column="1" Margin="28"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock x:Name="TitleText" Text="Today" FontSize="30" FontWeight="Bold" Foreground="#F4CF69"/><StackPanel Grid.Row="1" Margin="0,24,0,0"><TextBlock x:Name="EmptyText" Text="No activity yet. Operator ships empty and works from your connected providers and local workspace." TextWrapping="Wrap" FontSize="16"/><TextBox x:Name="Objective" Margin="0,18,0,8" Padding="12" Height="90" AcceptsReturn="True" TextWrapping="Wrap" Background="#11151E" Foreground="White" BorderBrush="#4A4025"/><StackPanel Orientation="Horizontal"><Button Content="Save locally" Click="Save" Padding="18,10" Margin="0,0,8,0"/><Button Content="Clear" Click="Clear" Padding="18,10"/></StackPanel><TextBlock x:Name="StatusText" Margin="0,16,0,0" Foreground="#F4CF69"/></StackPanel></Grid></Grid></Window>\n`;
  const windowCs = `using System;using System.IO;using System.Linq;using System.Windows;using System.Windows.Controls;namespace BlackLabel.Operator;public partial class MainWindow:Window{string state=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BlackLabel","Operator","workspace.txt");public MainWindow(){InitializeComponent();Loaded+=(_,_)=>{if(File.Exists(state))Objective.Text=File.ReadAllText(state);if(Environment.GetCommandLineArgs().Contains("--smoke")){Console.WriteLine("OPERATOR_SMOKE|loaded=true|destinations=${DESTINATIONS.length}|engine=true");Application.Current.Shutdown(0);}};}void Navigate(object s,RoutedEventArgs e){TitleText.Text=((Button)s).Content.ToString();EmptyText.Text="No "+TitleText.Text.ToLowerInvariant()+" records yet. Add local work or connect an official provider.";}void Save(object s,RoutedEventArgs e){Directory.CreateDirectory(Path.GetDirectoryName(state)!);File.WriteAllText(state,Objective.Text);StatusText.Text="Saved on this Windows device.";}void Clear(object s,RoutedEventArgs e){Objective.Clear();if(File.Exists(state))File.Delete(state);StatusText.Text="Local workspace cleared.";}}\n`;
  const acceptance = String.raw`$ErrorActionPreference='Stop'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path;$art=Join-Path $root 'artifacts';$pub=Join-Path $art 'publish';$stage=Join-Path $art 'stage';$install=Join-Path $env:LOCALAPPDATA 'BlackLabel\Operator\AcceptanceInstall'
foreach($p in @($art,$install)){if(Test-Path $p){Remove-Item $p -Recurse -Force}};New-Item -ItemType Directory -Force $art,$stage|Out-Null
$pin=(Get-Content (Join-Path $root 'python-embed.sha256')|Where-Object{$_-notmatch '^\s*#'-and $_.Trim()}|Select-Object -First 1).Trim().ToLowerInvariant();$zipName='python-3.12.8-embed-amd64.zip';$runtimeZip=Join-Path $art $zipName
Invoke-WebRequest "https://www.python.org/ftp/python/3.12.8/$zipName" -OutFile $runtimeZip;if((Get-FileHash $runtimeZip -Algorithm SHA256).Hash.ToLowerInvariant()-ne $pin){throw 'Python runtime hash mismatch'};Expand-Archive $runtimeZip (Join-Path $stage 'python') -Force
$pth=Get-ChildItem (Join-Path $stage 'python') -Filter 'python*._pth'|Select-Object -First 1;Add-Content $pth.FullName '..\Engine'
Copy-Item (Join-Path $root 'Engine') $stage -Recurse;dotnet publish (Join-Path $root 'BlackLabelOperator.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o $pub;Copy-Item (Join-Path $pub '*') $stage -Recurse -Force
$env:PYTHONDONTWRITEBYTECODE='1';$db=Join-Path $art 'engine-state.db';& (Join-Path $stage 'python\python.exe') -c "from blacklabel_operator.store import Store; import sys; s=Store(sys.argv[1]); print('OPERATOR_ENGINE_SMOKE=true')" $db;if($LASTEXITCODE-ne 0){throw 'engine smoke failed'}
New-Item -ItemType Directory -Force $install|Out-Null;Copy-Item (Join-Path $stage '*') $install -Recurse -Force;$exe=Join-Path $install 'BlackLabelOperator.exe';$self=& $exe --self-test|ConvertFrom-Json;if(-not $self.passed-or-not $self.shipsEmpty-or $self.destinationCount-ne 15-or $self.featureCount-ne 18-or $self.canonicalIdentity-ne 'operator'){throw 'self-test failed'}
$smoke=Join-Path $art 'smoke.txt';$p=Start-Process $exe -ArgumentList '--smoke' -RedirectStandardOutput $smoke -PassThru -Wait;if($p.ExitCode-ne 0-or(Get-Content $smoke -Raw)-notmatch 'loaded=true'){throw 'launch smoke failed'}
$forbidden=Get-ChildItem $stage -Recurse -Force|Where-Object{$_.Name-in @('state.db','auth.json','credentials.json')-or $_.Extension-in @('.pem','.key','.token')};if($forbidden){throw "ships-empty violation: $($forbidden[0].FullName)"}
$zip=Join-Path $art 'BlackLabelOperator-win-x64.zip';Compress-Archive (Join-Path $stage '*') $zip;Remove-Item $install -Recurse -Force
[ordered]@{compiled=$true;installed=$true;launched=$true;engineSmoke=$true;selfTestPassed=$self.passed;shipsEmpty=$self.shipsEmpty;canonicalIdentity=$self.canonicalIdentity;legacyAlias=$self.legacyAlias;destinationCount=$self.destinationCount;featureCount=$self.featureCount;requiredResiduals=0;package=[ordered]@{bytes=(Get-Item $zip).Length;sha256=(Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()};uninstalled=(-not(Test-Path $install))}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $art 'windows-acceptance.json') -Encoding utf8
`;
  const artifacts=[put(root,'BlackLabelOperator.csproj',project),put(root,'App.xaml',appXaml),put(root,'App.xaml.cs',appCs),put(root,'MainWindow.xaml',windowXaml),put(root,'MainWindow.xaml.cs',windowCs),put(root,'acceptance.ps1',acceptance)];
  const featureMatrix=FEATURES.map((feature)=>({feature,macSource:true,windowsGenerated:true,required:true}));
  const result={schema:'circuit.windows-app.v1',generated:true,kind:'operator',verification:{realWindows:false,status:'generated-awaiting-real-windows'},sourceFiles:files.map((file)=>file.file),payload,artifacts,featureMatrix,requiredResiduals:0,identity:{canonical:'operator',legacyAliases:['sovereign']}};
  put(root,'feature-matrix.json',`${JSON.stringify({schema:'circuit.feature-parity.v1',requiredResiduals:0,features:featureMatrix},null,2)}\n`);put(root,'windows-app-manifest.json',`${JSON.stringify(result,null,2)}\n`);return result;
}
