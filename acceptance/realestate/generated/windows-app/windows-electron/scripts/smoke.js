// Deterministic smoke test: prove the shell actually RENDERS the staged payload.
//
// A launch that prints no errors is not evidence — the Academy sibling exited 0 with an empty
// log while rendering a 37-character fallback. This harness loads the window through the SAME
// protocol main.js uses and reads facts back out of the live DOM.
//
// SCOPE: this asserts the SHELL renders and Leaflet initialises. It deliberately does NOT
// assert that property data loaded — that needs the live api.blbestate.com plus a subscriber
// token, which is a network+credential test, not a packaging one. A shell test that silently
// depended on a live API would fail for reasons that have nothing to do with the build.
const { app, BrowserWindow } = require("electron");
const { INDEX, registerUiScheme, serveUi } = require("../serve.js");

registerUiScheme();

const MINIMUM = Object.freeze({ elements: 50, textLength: 200 });

app.whenReady().then(async () => {
  serveUi();
  const win = new BrowserWindow({
    width: 1400, height: 900, show: false,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true },
  });
  const failures = [];
  win.webContents.on("console-message", (_event, level, message) => {
    // Electron's dev-only CSP advisory is not an app defect and does not appear in a packaged
    // build. Offline API complaints are expected here (see SCOPE above) and are not failures.
    const benign = message.includes("Electron Security Warning")
      || /api\.blbestate\.com|tile\.openstreetmap\.org|Can't reach the property database/i.test(message);
    if (level >= 2 && !benign) failures.push(`renderer console error: ${message}`);
  });
  try {
    await win.loadURL(INDEX);
    await new Promise((resolve) => setTimeout(resolve, 1500));
    // The map is built by viewMap(), which only runs when the Map tab is selected — it is NOT
    // part of the boot render. So the test walks the real user path (click the tab) instead of
    // asserting on boot state and calling a correctly-idle map a failure.
    const opened = await win.webContents.executeJavaScript(`(() => {
      const tab = document.querySelector('#tabs [data-tab="map"]');
      if (!tab) return false;
      tab.click();
      return true;
    })()`);
    if (!opened) failures.push("no [data-tab=\"map\"] control found — the app shell did not render its tabs");
    await new Promise((resolve) => setTimeout(resolve, 2500));
    const facts = await win.webContents.executeJavaScript(`(() => ({
      url: location.href,
      title: document.title,
      bodyTextLength: (document.body.innerText || "").trim().length,
      elementCount: document.getElementsByTagName("*").length,
      appChildren: (document.getElementById("app") || { children: [] }).children.length,
      // The whole reason vendor/leaflet is staged: if it did not load, the map is a blank box.
      leafletLoaded: typeof window.L === "object" && typeof (window.L || {}).map === "function",
      // BLRE_API is declared with a top-level \`const\` in a classic script, so it is a global
      // LEXICAL binding — it never appears on window. Test the binding, not the property.
      apiModulePresent: typeof BLRE_API === "object",
      mapPanes: document.querySelectorAll(".leaflet-pane").length,
      tileLayerRequested: document.querySelectorAll(".leaflet-tile").length > 0,
    }))()`);
    if (!facts.title) failures.push("document has no title");
    if (!facts.appChildren) failures.push("#app is empty — app.js never rendered");
    if (!facts.leafletLoaded) failures.push("Leaflet did not load — vendor payload missing or blocked");
    if (!facts.apiModulePresent) failures.push("BLRE_API module did not evaluate");
    if (facts.mapPanes < 1) failures.push("Map tab opened but no Leaflet panes rendered — the map did not initialise");
    if (facts.elementCount < MINIMUM.elements) failures.push(`only ${facts.elementCount} elements rendered (need ${MINIMUM.elements}+)`);
    if (facts.bodyTextLength < MINIMUM.textLength) failures.push(`only ${facts.bodyTextLength} chars of visible text (need ${MINIMUM.textLength}+)`);
    console.log(JSON.stringify(facts, null, 2));
  } catch (error) {
    failures.push(`load failed: ${error?.message || error}`);
  }
  for (const failure of failures) console.error(`SMOKE FAIL: ${failure}`);
  console.log(failures.length ? "VERDICT: FAILED" : "VERDICT: PASSED — shell rendered the payload");
  app.exit(failures.length ? 1 : 0);
});
