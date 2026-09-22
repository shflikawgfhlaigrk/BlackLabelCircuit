// Serve the UI payload over a real origin instead of file://.
//
// The Academy sibling proved why this is not optional: under file:// the opaque origin blocks
// the app's own fetches, the page still loads, and it renders a fallback instead of failing —
// a silent half-broken app. The Tauri shell avoids it by serving from a custom asset protocol;
// this is the Electron equivalent, so both shells present the payload the same way.
//
// This app additionally talks OUT to https://api.blbestate.com (the property database) and
// https://tile.openstreetmap.org (map tiles). A privileged standard+secure scheme gives those
// requests a normal origin; the API answers `access-control-allow-origin: *`, so the Electron
// origin reaches it exactly as the Tauri one does.
const { protocol, net } = require("electron");
const { join, normalize, sep } = require("node:path");
const { pathToFileURL } = require("node:url");

const SCHEME = "app";
const HOST = "blre";
const ROOT = join(__dirname, "app", "ui");
const INDEX = `${SCHEME}://${HOST}/index.html`;

// Must run before app 'ready'.
function registerUiScheme() {
  protocol.registerSchemesAsPrivileged([{
    scheme: SCHEME,
    privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true },
  }]);
}

// Must run after app 'ready'.
function serveUi() {
  protocol.handle(SCHEME, (request) => {
    const url = new URL(request.url);
    if (url.host !== HOST) return new Response("not found", { status: 404 });
    const relative = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "index.html";
    const target = normalize(join(ROOT, relative));
    // The staged payload is the entire world this shell may read. Anything resolving outside
    // it — traversal, absolute path — is refused rather than served.
    if (target !== ROOT && !target.startsWith(ROOT + sep)) return new Response("forbidden", { status: 403 });
    return net.fetch(pathToFileURL(target).toString());
  });
}

module.exports = { registerUiScheme, serveUi, INDEX, SCHEME, HOST, ROOT };
