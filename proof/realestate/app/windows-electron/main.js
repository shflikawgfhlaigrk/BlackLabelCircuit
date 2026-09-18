// Electron shell for the Black Label Real Estate Windows UI.
//
// This is a SHELL ONLY. Every byte it renders comes from ../windows/ui, the same payload
// tauri.conf.json points frontendDist at; scripts/stage.mjs refuses to run unless the staged
// copy is byte-identical. Any difference measured between the two shells is the SHELL.
//
// Window geometry is copied verbatim from ../windows/src-tauri/tauri.conf.json so the
// comparison is not confounded by a different viewport.
const { app, BrowserWindow, shell } = require("electron");
const { INDEX, registerUiScheme, serveUi } = require("./serve.js");

// Matches tauri.conf.json app.windows[0] exactly.
const WINDOW = Object.freeze({ width: 1400, height: 900, minWidth: 980, minHeight: 640 });

// Privileged scheme registration only takes effect before 'ready'.
registerUiScheme();

function createWindow() {
  const win = new BrowserWindow({
    ...WINDOW,
    title: "Black Label Real Estate",
    resizable: true,
    show: false,
    webPreferences: {
      // The UI asks for no privileged API — it reaches its data over ordinary fetch. Keep the
      // renderer fully sandboxed so this shell grants strictly less than the Tauri one.
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  // The subscriber's Bearer token lives in this renderer's localStorage. Nothing may navigate
  // the app window off its own origin — an external link opens in the real browser instead,
  // where it cannot read that storage.
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  win.webContents.on("will-navigate", (event, url) => {
    if (!url.startsWith(`app://`)) {
      event.preventDefault();
      if (/^https:\/\//.test(url)) shell.openExternal(url);
    }
  });

  win.once("ready-to-show", () => win.show());
  return win.loadURL(INDEX).then(() => win);
}

app.whenReady().then(async () => {
  serveUi();
  await createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
