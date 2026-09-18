// Circuit-Win shell — Tauri v2.  STAGED: built in the W0 Windows VM (the Rust
// toolchain lives in the build rig, per the plan); unsigned until the Authenticode
// cert exists (2026-07-21).  This file ports the 241-line macOS launcher
// (macos/CircuitLauncher.swift + macos/launcher.sh) 1:1 — see docs/windows-shell-spike.md:
//   * repo picker + recents        (NSOpenPanel / `choose folder`  -> dialog plugin)
//   * spawn `node server.js <repo>` (Process                        -> shell sidecar)
//   * follow stdout to the real http://localhost:PORT  (port climbs past the default
//     on EADDRINUSE; the shell follows the server, it never hardcodes a port)
//   * navigate the window there     (standalone Chrome window       -> WebviewWindow)
//   * kill the child cleanly on exit (SIGTERM/kill                  -> CommandChild.kill)
//
// The Rust below is verified by `cargo check` in the VM (first build gate); it is not
// compiled on the darwin authoring machine.  The one cross-language seam that CAN be
// proven on darwin — the server's stdout URL contract this shell keys on — is locked by
// test/winshell.test.js (parse_localhost_url has an exact JS mirror there).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use tauri::{Manager, RunEvent, WindowEvent};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_shell::process::{CommandChild, CommandEvent};
use tauri_plugin_shell::ShellExt;

/// The running node child, so it can be killed on exit.  Windows does not reap a
/// child with its parent, so an explicit kill is mandatory (plan §W1 "clean child
/// shutdown") — a leaked node server would hold the repo's files and a port.
struct ServerChild(Mutex<Option<CommandChild>>);

const RECENTS_FILE: &str = "recent-repos.txt";
const MAX_RECENTS: usize = 8;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(ServerChild(Mutex::new(None)))
        .setup(|app| {
            let handle = app.handle().clone();

            // A folder passed on the command line (`Circuit <repo>`, `open -a Circuit
            // --args <repo>`) opens directly; otherwise the repo picker (recents seed
            // the default location) — mirrors the macOS launcher.  Non-directory args
            // (e.g. a Finder `-psn_…` token) are ignored.  A cancel means "nothing to
            // grade": quit cleanly.
            let from_args = std::env::args().skip(1).map(PathBuf::from).find(|p| p.is_dir());
            let repo = match from_args.or_else(|| choose_repository(&handle)) {
                Some(r) => r,
                None => {
                    handle.exit(0);
                    return Ok(());
                }
            };
            remember(&handle, &repo);

            // Resolve the bundled server; honest dialog + quit if it is missing
            // (mirrors the Swift preflight()).
            let server_js = handle
                .path()
                .resource_dir()
                .map(|d| d.join("app").join("server.js"))
                .map_err(|e| format!("no resource dir: {e}"))?;
            if !server_js.exists() {
                handle
                    .dialog()
                    .message("The bundled Circuit server is missing.")
                    .title("Circuit cannot start")
                    .blocking_show();
                handle.exit(1);
                return Ok(());
            }

            start_server(&handle, server_js, repo)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { .. } = event {
                kill_server(window.app_handle());
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building Circuit")
        .run(|app_handle, event| {
            if let RunEvent::ExitRequested { .. } = event {
                kill_server(app_handle);
            }
        });
}

/// Native folder picker, defaulting to the most-recent repo's parent.  Recents are
/// only a convenience seed; the folder chosen here is authoritative.
fn choose_repository(app: &tauri::AppHandle) -> Option<PathBuf> {
    let recents = recent_repositories(app);
    let mut picker = app
        .dialog()
        .file()
        .set_title("Choose a repo for Circuit to grade");
    if let Some(parent) = recents.first().and_then(|r| r.parent()) {
        picker = picker.set_directory(parent);
    }
    picker.blocking_pick_folder().and_then(|p| p.into_path().ok())
}

fn recents_path(app: &tauri::AppHandle) -> Option<PathBuf> {
    app.path()
        .app_config_dir()
        .ok()
        .map(|d| d.join(RECENTS_FILE))
}

/// Existing directories only, deduped, most-recent first, capped at 8 — the exact
/// contract of the macOS `recentRepositories()` / launcher.sh CLEAN loop.
fn recent_repositories(app: &tauri::AppHandle) -> Vec<PathBuf> {
    let Some(path) = recents_path(app) else {
        return Vec::new();
    };
    let Ok(text) = fs::read_to_string(&path) else {
        return Vec::new();
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut out: Vec<PathBuf> = Vec::new();
    for line in text.lines() {
        let p = line.trim();
        if p.is_empty() || !seen.insert(p.to_string()) {
            continue;
        }
        let pb = PathBuf::from(p);
        if pb.is_dir() {
            out.push(pb);
        }
        if out.len() >= MAX_RECENTS {
            break;
        }
    }
    out
}

/// Push `repo` to the front of recents (dedupe, cap 8), mirroring `remember()`.
fn remember(app: &tauri::AppHandle, repo: &PathBuf) {
    let Some(path) = recents_path(app) else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let chosen = repo.to_string_lossy().to_string();
    let mut lines = vec![chosen.clone()];
    for r in recent_repositories(app) {
        let s = r.to_string_lossy().to_string();
        if s != chosen {
            lines.push(s);
        }
    }
    lines.truncate(MAX_RECENTS);
    let _ = fs::write(&path, lines.join("\n") + "\n");
}

/// Spawn the bundled node server on the chosen repo and follow its stdout to the
/// live URL.  No `--port`: the server picks/climbs and PRINTS its real URL, which we
/// follow — identical to the macOS launcher (a buyer's Windows box has no hands-off
/// :8923; that rule is a dev-machine concern only).
fn start_server(
    app: &tauri::AppHandle,
    server_js: PathBuf,
    repo: PathBuf,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut args = vec![
        server_js.to_string_lossy().to_string(),
        repo.to_string_lossy().to_string(),
    ];
    // CIRCUIT_PORT pins the server's port (dev machines keep the default port
    // hands-off; a buyer with a port clash can move it). Invalid values are ignored.
    if let Some(port) = std::env::var("CIRCUIT_PORT").ok().filter(|p| p.parse::<u16>().is_ok()) {
        args.push("--port".to_string());
        args.push(port);
    }
    // CIRCUIT_PARENT_WATCH: the server exits when this shell's end of its stdin pipe
    // closes — i.e. when the shell dies WITHOUT running its exit handler (a kill, a
    // crash). The normal quit path still kills the child explicitly below; this covers
    // the rest, so a dead window never leaves a server holding a port.
    let sidecar = app.shell().sidecar("node")?.args(args).env("CIRCUIT_PARENT_WATCH", "1");
    let (mut rx, child) = sidecar.spawn()?;
    *app.state::<ServerChild>().0.lock().unwrap() = Some(child);

    let handle = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut buffer = String::new();
        let mut opened = false;
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(bytes) | CommandEvent::Stderr(bytes) => {
                    if opened {
                        continue;
                    }
                    buffer.push_str(&String::from_utf8_lossy(&bytes));
                    if let Some(url) = parse_localhost_url(&buffer) {
                        opened = true;
                        navigate_main_window(&handle, url);
                    }
                }
                // The grading server exited before announcing a URL — nothing to
                // show; quit (mirrors the Swift terminationHandler).
                CommandEvent::Terminated(_) => {
                    if !opened {
                        let h = handle.clone();
                        let _ = handle.run_on_main_thread(move || h.exit(1));
                    }
                    break;
                }
                _ => {}
            }
        }
    });
    Ok(())
}

/// Find the first COMPLETE `http://localhost:<port>` in the accumulated server
/// output.  "Complete" = the digit run is terminated by a non-digit, so we never
/// navigate to a port truncated mid-write across two stdout chunks.  Exact JS mirror
/// (and the failure cases) live in test/winshell.test.js.
fn parse_localhost_url(buf: &str) -> Option<String> {
    const NEEDLE: &str = "http://localhost:";
    let start = buf.find(NEEDLE)?;
    let after = &buf[start + NEEDLE.len()..];
    let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        return None;
    }
    // No boundary yet (the chunk ended exactly on a digit) — wait for more output
    // rather than opening a possibly-truncated port.
    if digits.len() == after.len() {
        return None;
    }
    Some(format!("{NEEDLE}{digits}"))
}

fn navigate_main_window(app: &tauri::AppHandle, url: String) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        if let Some(win) = app.get_webview_window("main") {
            if let Ok(parsed) = url.parse::<tauri::Url>() {
                let _ = win.navigate(parsed);
                let _ = win.show();
                let _ = win.set_focus();
            }
        }
    });
}

fn kill_server(app: &tauri::AppHandle) {
    if let Some(child) = app.state::<ServerChild>().0.lock().unwrap().take() {
        let _ = child.kill();
    }
}
