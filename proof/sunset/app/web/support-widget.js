/* support-widget.js — the on-site support helper.
 *
 * BRAND-NEUTRAL BY CONSTRUCTION: this file contains no brand name, no domain and
 * no email. Every site-specific string arrives from data-attributes on the script
 * tag, so one identical file ships to all five sites without any of them being
 * able to leak another's identity.
 *
 *   <script src="/support-widget.js" defer
 *           data-brand="Sunset"
 *           data-endpoint="/api/support"
 *           data-escalation="/support/"
 *           data-accent="#e8734a"></script>
 *
 * DESIGN: these are premium properties, so this avoids the stock live-chat look
 * entirely — no coloured speech bubbles, no filled blob launcher, no rounded pill
 * messages. It reads as a TRANSCRIPT.
 *
 * The panel is DISTINCT BUT HARMONIOUS (founder direction): it does not imitate the
 * host page, it is its own assistant layer sitting deliberately over the brand —
 * darker, sharper, glassy, with a fine grain and a light-from-above edge. The only
 * things it inherits are the typeface and the accent colour, which is used as a
 * LINE and a MARK, never as a fill.
 *
 * No external requests, no fonts, no analytics. Talks only to its own origin.
 */
(function () {
  "use strict";

  var script =
    document.currentScript ||
    (function () {
      var s = document.querySelectorAll("script[data-endpoint]");
      return s[s.length - 1];
    })();
  if (!script) return;

  var BRAND = script.getAttribute("data-brand") || "Support";
  var ENDPOINT = script.getAttribute("data-endpoint") || "/api/support";
  var ESCALATION_RAW = script.getAttribute("data-escalation") || "/";
  var ACCENT = script.getAttribute("data-accent") || "#c9a227";
  // The launcher label. "Ask" reads flat; on these properties the concierge
  // register is the point. Per-site override via data-label.
  var LABEL = script.getAttribute("data-label") || "Assistance";
  // Monogram for the seal — the brand's own initial, so the file stays brand-free.
  var MONOGRAM = (BRAND.match(/[A-Za-z]/) || ["A"])[0].toUpperCase();
  var GREETING =
    script.getAttribute("data-greeting") ||
    "Ask anything about " + BRAND + ", or anything else you're wondering about. " +
      "I'm automated \u2014 please verify anything important.";

  if (window.__blSupportWidget) return;
  window.__blSupportWidget = true;

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  // URLs from data attributes and API responses are untrusted sinks. Parse with
  // the browser's URL implementation (which normalises control characters) and
  // allow only schemes that cannot execute script. The stylesheet allowlist is
  // deliberately narrower because mail and telephone URLs are not CSS assets.
  var LINK_SCHEMES = ["https:", "http:", "mailto:", "tel:"];
  var ASSET_SCHEMES = ["https:", "http:"];

  function safeUrl(value, allowed, fallback) {
    var raw = String(value == null ? "" : value);
    if (!raw) return fallback;
    try {
      var parsed = new URL(raw, document.baseURI);
      return allowed.indexOf(parsed.protocol) === -1 ? fallback : parsed.href;
    } catch (e) {
      return fallback;
    }
  }

  var ESCALATION = safeUrl(ESCALATION_RAW, LINK_SCHEMES, "/");

  // ---------------------------------------------------------------- styles
  // A fine grain, as an inline SVG data URI. No network request; gives the panel a
  // tactile, printed quality instead of flat digital black.
  var GRAIN =
    "url(\"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='140'>" +
    "<filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.82' numOctaves='3'/></filter>" +
    "<rect width='140' height='140' filter='url(%23n)' opacity='.5'/></svg>\")";

  var css = [
    ".bl-sup{position:fixed;right:20px;bottom:20px;z-index:2147483000;color-scheme:dark;" +
      "font-family:inherit;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}",
    ".bl-sup *{box-sizing:border-box}",
    ".bl-sup.collision-hidden:not(.open){opacity:0;visibility:hidden;pointer-events:none}",
    ".bl-sup ::selection{background:var(--bl-accent);color:#08080a}",
    // One editorial serif for the wordmark. Everything else inherits the site.
    ".bl-sup-serif{font-family:Georgia,'Iowan Old Style','Times New Roman',serif}",

    /* ---------------- launcher ----------------
       This is the only thing on screen most of the time, so it carries the whole
       impression. A 4px status dot beside the word "Ask" read like a support
       widget; this is a struck seal — a hairline metallic ring around the brand's
       own initial, with a serif label — sitting on a deep plate lit along its top
       edge. Understated, and legible over a bright hero. */
    ".bl-sup-btn{position:relative;display:inline-flex;width:52px;height:52px;align-items:center;justify-content:center;gap:0;cursor:pointer;" +
      "padding:8px;border-radius:50%;background:#08080a;" +
      "border:1px solid rgba(255,255,255,.09);" +
      "color:rgba(255,255,255,.88);font-size:13.5px;letter-spacing:.13em;" +
      "box-shadow:0 1px 0 rgba(255,255,255,.06) inset,0 22px 60px -18px rgba(0,0,0,.95);" +
      "transition:transform .5s cubic-bezier(.16,.7,.3,1),border-color .5s ease}",
    ".bl-sup-btn:before{content:'';position:absolute;left:14%;right:14%;top:-1px;height:1px;" +
      "background:linear-gradient(90deg,transparent,var(--bl-accent),transparent);opacity:.8;" +
      "transition:opacity .5s ease}",
    ".bl-sup-btn:hover{transform:translateY(-2px);border-color:rgba(255,255,255,.16)}",
    ".bl-sup-btn:hover:before{opacity:1}",
    ".bl-sup-btn:hover .bl-sup-seal{border-color:color-mix(in srgb,var(--bl-accent) 75%,transparent)}",
    ".bl-sup-btn:focus-visible{outline:3px solid #fff;outline-offset:3px;box-shadow:0 0 0 6px #08080a,0 22px 60px -18px rgba(0,0,0,.95)}",
    ".bl-sup-btn>span:last-child{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;" +
      "clip:rect(0,0,0,0);clip-path:inset(50%);white-space:nowrap;border:0}",
    // The seal: hairline ring + metallic monogram.
    ".bl-sup-seal{display:flex;align-items:center;justify-content:center;flex:0 0 auto;" +
      "width:34px;height:34px;border-radius:50%;" +
      "border:1px solid color-mix(in srgb,var(--bl-accent) 42%,transparent);" +
      "font-size:14px;line-height:1;padding-bottom:1px;" +
      "background:radial-gradient(circle at 50% 12%,rgba(255,255,255,.09),transparent 68%);" +
      "transition:border-color .5s ease}",
    ".bl-sup-seal span{background:linear-gradient(105deg,#fff 4%,color-mix(in srgb,var(--bl-accent) 90%,#fff) 48%,#fff 96%);" +
      "-webkit-background-clip:text;background-clip:text;color:transparent}",

    /* ---------------- panel ----------------
       Wider and quieter than before. Luxury here is AIR and restraint, not more
       ornament: generous padding, few controls, a deep black lifted by a soft
       radial glow at the top edge. Base alpha stays near-solid so legibility never
       depends on the blur compositing. */
    ".bl-sup-panel{position:absolute;right:0;bottom:0;width:448px;max-width:calc(100vw - 36px);" +
      "height:min(600px,calc(100vh - 140px));display:none;flex-direction:column;overflow:hidden;border-radius:2px;" +
      "background:" +
        "radial-gradient(120% 55% at 50% -12%,rgba(255,255,255,.07),transparent 60%)," +
        "rgba(7,7,8,.985);" +
      "-webkit-backdrop-filter:blur(34px) saturate(1.5);backdrop-filter:blur(34px) saturate(1.5);" +
      "border:1px solid rgba(255,255,255,.085);" +
      "box-shadow:0 1px 0 rgba(255,255,255,.07) inset,0 50px 120px -30px rgba(0,0,0,.95);" +
      "opacity:1}",
    ".bl-sup-panel:after{content:'';position:absolute;left:0;right:0;top:0;height:1px;pointer-events:none;" +
      "background:linear-gradient(90deg,transparent,color-mix(in srgb,var(--bl-accent) 60%,transparent),transparent)}",
    "@keyframes bl-in{from{opacity:0;transform:translateY(14px) scale(.99)}to{opacity:1;transform:none}}",
    ".bl-sup.open .bl-sup-panel{display:flex;animation:bl-in .5s cubic-bezier(.16,.7,.3,1) both}",
    ".bl-sup.open .bl-sup-btn{opacity:0;visibility:hidden;pointer-events:none}",

    /* ---------------- header: a wordmark, not a title bar ---------------- */
    ".bl-sup-hd{display:flex;align-items:center;justify-content:space-between;padding:30px 30px 0;flex:0 0 auto}",
    // Metallic sheen on the wordmark rather than a flat accent fill.
    ".bl-sup-ttl{font-size:19px;letter-spacing:.02em;line-height:1;" +
      "background:linear-gradient(100deg,#fff 8%,color-mix(in srgb,var(--bl-accent) 85%,#fff) 46%,#fff 92%);" +
      "-webkit-background-clip:text;background-clip:text;color:transparent}",
    ".bl-sup-x{display:inline-flex;align-items:center;justify-content:center;width:44px;height:44px;background:none;" +
      "border:0;color:rgba(255,255,255,.76);cursor:pointer;font-size:17px;line-height:1;" +
      "padding:0;margin:-12px -12px -12px 0;transition:color .3s ease}",
    ".bl-sup-x:hover{color:rgba(255,255,255,.95)}",

    /* ---------------- transcript ---------------- */
    ".bl-sup-log{flex:1 1 auto;overflow-y:auto;padding:8px 30px 20px;scrollbar-width:thin;" +
      "scrollbar-color:rgba(255,255,255,.12) transparent}",
    ".bl-sup-log::-webkit-scrollbar{width:10px}",
    ".bl-sup-log::-webkit-scrollbar-track{background:transparent}",
    ".bl-sup-log::-webkit-scrollbar-thumb{background:rgba(255,255,255,.1);border:4px solid transparent;" +
      "background-clip:content-box;border-radius:10px}",
    "@keyframes bl-rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}",
    ".bl-sup-row{padding:22px 0;animation:bl-rise .45s cubic-bezier(.16,.7,.3,1) both}",
    ".bl-sup-row+.bl-sup-row{border-top:1px solid rgba(255,255,255,.045)}",
    ".bl-sup-lbl{font-size:9px;letter-spacing:.3em;text-transform:uppercase;" +
      "color:rgba(255,255,255,.68);margin-bottom:11px}",
    ".bl-sup-q .bl-sup-lbl{color:rgba(255,255,255,.72)}",
    ".bl-sup-txt{font-size:14.5px;line-height:1.78;color:rgba(255,255,255,.87);white-space:pre-wrap;" +
      "word-wrap:break-word;overflow-wrap:anywhere;letter-spacing:.002em}",
    ".bl-sup-q .bl-sup-txt{color:rgba(255,255,255,.74);font-size:14px}",

    /* ---------------- provenance ---------------- */
    ".bl-sup-src{margin-top:16px;font-size:9.5px;letter-spacing:.06em;color:rgba(255,255,255,.68);line-height:1.7}",
    ".bl-sup-src b{font-weight:400;letter-spacing:.26em;text-transform:uppercase;" +
      "color:rgba(255,255,255,.72);margin-right:9px;font-size:8.5px}",
    ".bl-sup-esc{display:inline-block;margin-top:16px;font-size:13px;letter-spacing:.03em;" +
      "color:var(--bl-accent);text-decoration:none;" +
      "border-bottom:1px solid color-mix(in srgb,var(--bl-accent) 35%,transparent);padding-bottom:3px;" +
      "transition:border-color .3s ease}",
    ".bl-sup-esc:hover{border-bottom-color:var(--bl-accent)}",

    /* ---------------- privacy and emergency boundary ---------------- */
    ".bl-sup-note{flex:0 0 auto;margin:0;padding:13px 30px 14px;color:rgba(255,255,255,.72);" +
      "font-size:11px;line-height:1.55;border-top:1px solid rgba(255,255,255,.08)}",
    ".bl-sup-sr{position:absolute!important;width:1px!important;height:1px!important;padding:0!important;margin:-1px!important;" +
      "overflow:hidden!important;clip:rect(0,0,0,0)!important;white-space:nowrap!important;border:0!important}",

    /* ---------------- thinking ---------------- */
    ".bl-sup-dots{display:inline-flex;gap:6px;align-items:center;padding:6px 0}",
    ".bl-sup-dots i{width:3px;height:3px;border-radius:50%;background:var(--bl-accent);animation:bl-b 1.5s ease-in-out infinite}",
    ".bl-sup-dots i:nth-child(2){animation-delay:.18s}.bl-sup-dots i:nth-child(3){animation-delay:.36s}",
    "@keyframes bl-b{0%,70%,100%{opacity:.18}35%{opacity:1}}",

    /* ---------------- composer: no button, just a rule and a return hint ---------------- */
    ".bl-sup-fm{position:relative;display:grid;grid-template-columns:minmax(0,1fr) 44px;align-items:center;" +
      "column-gap:14px;row-gap:4px;padding:20px 30px 26px;flex:0 0 auto}",
    ".bl-sup-fm:before{content:'';position:absolute;left:30px;right:30px;top:0;height:1px;background:rgba(255,255,255,.06)}",
    ".bl-sup-compose-label{grid-column:1/-1;color:rgba(255,255,255,.78);font-size:10px;font-weight:700;" +
      "letter-spacing:.18em;line-height:1.4;text-transform:uppercase}",
    ".bl-sup-in{flex:1 1 auto;background:transparent;border:0;color:rgba(255,255,255,.95);" +
      "grid-column:1;padding:6px 0;font-size:14.5px;resize:none;max-height:98px;line-height:1.6;font-family:inherit}",
    ".bl-sup-in:focus-visible{outline:3px solid #fff;outline-offset:4px}",
    ".bl-sup-in::placeholder{color:rgba(255,255,255,.66);letter-spacing:.01em;opacity:1}",
    ".bl-sup-go{display:inline-flex;align-items:center;justify-content:center;flex:0 0 44px;width:44px;height:44px;" +
      "background:none;border:0;cursor:pointer;color:rgba(255,255,255,.72);padding:0;margin:-10px -12px -10px 0;" +
      "font-size:17px;line-height:1;transition:color .3s ease}",
    ".bl-sup-go.on{color:#fff}",
    ".bl-sup-go:disabled{opacity:.45;cursor:default}",
    ".bl-sup-x:focus-visible,.bl-sup-go:focus-visible,.bl-sup-esc:focus-visible,.bl-sup-log:focus-visible{" +
      "outline:3px solid #fff;outline-offset:3px}",

    "@media (prefers-reduced-motion:reduce){.bl-sup-btn,.bl-sup-dots i{transition:none;animation:none}" +
      ".bl-sup.open .bl-sup-panel,.bl-sup-row{animation:none}}",
    "@media (max-width:500px){.bl-sup{right:12px;bottom:12px;left:auto}" +
      ".bl-sup.open{left:12px;right:12px}" +
      ".bl-sup-panel{width:auto;left:0;right:0;height:calc(100vh - 120px);height:calc(100dvh - 120px)}" +
      ".bl-sup-hd{padding:24px 22px 0}.bl-sup-log{padding:8px 22px 18px}.bl-sup-note{padding:12px 22px 13px}" +
      ".bl-sup-fm{padding:18px 22px 22px}" +
      ".bl-sup-fm:before{left:22px;right:22px}}",
    "@media (forced-colors:active){.bl-sup-btn,.bl-sup-x,.bl-sup-go,.bl-sup-in,.bl-sup-esc,.bl-sup-log{" +
      "forced-color-adjust:auto}.bl-sup-btn:focus-visible,.bl-sup-x:focus-visible,.bl-sup-go:focus-visible," +
      ".bl-sup-in:focus-visible,.bl-sup-esc:focus-visible,.bl-sup-log:focus-visible{outline:3px solid Highlight}}",
  ].join("");

  // A host page may forbid inline stylesheets. Blackwater's origin sends a strict
  // `style-src 'self'` with no 'unsafe-inline', and under it this <style> block is
  // silently BLOCKED — the widget would mount with no styling at all and still look
  // like it "worked" to anything checking the DOM. Those lanes pass data-css and get
  // the identical rules as a same-origin stylesheet instead. install.mjs generates
  // that file FROM the array above, so the two can never drift.
  var CSSHREF = safeUrl(script.getAttribute("data-css"), ASSET_SCHEMES, "");
  var cssLink = null;
  if (CSSHREF) {
    cssLink = document.createElement("link");
    cssLink.rel = "stylesheet";
    cssLink.href = CSSHREF;
    document.head.appendChild(cssLink);
  } else {
    var style = document.createElement("style");
    style.textContent = css;
    document.head.appendChild(style);
  }

  // ---------------------------------------------------------------- markup
  var root = document.createElement("div");
  root.className = "bl-sup";
  root.style.setProperty("--bl-accent", ACCENT);
  root.innerHTML =
    '<button class="bl-sup-btn bl-sup-serif" type="button" aria-haspopup="dialog" aria-expanded="false">' +
      '<span class="bl-sup-seal bl-sup-serif" aria-hidden="true"><span>' + esc(MONOGRAM) + "</span></span>" +
      "<span>" + esc(LABEL) + "</span></button>" +
    '<div class="bl-sup-panel" role="dialog" aria-modal="true" aria-labelledby="bl-sup-title" ' +
      'aria-describedby="bl-sup-warning" aria-hidden="true" tabindex="-1">' +
      '<div class="bl-sup-hd">' +
        '<div class="bl-sup-ttl bl-sup-serif" id="bl-sup-title">' + esc(BRAND) + " assistant</div>" +
        '<button class="bl-sup-x" type="button" aria-label="Close ' + esc(BRAND) + ' assistant">&#10005;</button></div>' +
      '<div class="bl-sup-log" role="log" aria-live="polite" aria-relevant="additions text" ' +
        'aria-label="Conversation transcript" tabindex="0"></div>' +
      '<p class="bl-sup-note" id="bl-sup-warning">Do not enter health or emergency details, passwords, credentials, ' +
        'or other sensitive data. This assistant is not an emergency service.</p>' +
      '<form class="bl-sup-fm">' +
        '<label class="bl-sup-compose-label" for="bl-sup-question">Question</label>' +
        '<textarea class="bl-sup-in" id="bl-sup-question" rows="1" placeholder="Ask a question" ' +
          'aria-describedby="bl-sup-warning" maxlength="500"></textarea>' +
        '<button class="bl-sup-go" type="submit" aria-label="Send" disabled>&#8629;</button></form>' +
    "</div>";

  // An external stylesheet must load before the widget mounts. This avoids an
  // unstyled flash and a Chromium transition interpolation bug while retaining a
  // timed fail-safe if the stylesheet cannot load.
  var mounted = false;
  function mount() {
    if (mounted) return;
    mounted = true;
    document.body.appendChild(root);
    scheduleLauncherPlacement();
  }
  if (cssLink && !cssLink.sheet) {
    cssLink.addEventListener("load", mount);
    cssLink.addEventListener("error", mount);
    setTimeout(mount, 3000);
  } else {
    mount();
  }

  var btn = root.querySelector(".bl-sup-btn");
  var closeBtn = root.querySelector(".bl-sup-x");
  var log = root.querySelector(".bl-sup-log");
  var form = root.querySelector(".bl-sup-fm");
  var input = root.querySelector(".bl-sup-in");
  var send = root.querySelector(".bl-sup-go");
  var panel = root.querySelector(".bl-sup-panel");
  var previousFocus = null;
  var inertedSiblings = [];
  var placementFrame = 0;

  // The launcher must remain available without sitting on top of the host page's
  // own conversion controls, headings, or product imagery. Test a small set of
  // stable edge positions on every scroll/resize and choose the first clear one.
  // This keeps the closed control compact while protecting every responsive page,
  // including pages whose hero art moves below the fold on phones.
  var COLLISION_SELECTOR = [
    "main a", "main button", "main input", "main textarea", "main select", "main [role=button]",
    "main h1", "main h2", "main h3", "main img", "main video", "main .commerce-visual",
    "article a", "article button", "article h1", "article h2", "article h3", "article img", "article video",
    "footer a", "footer button",
  ].join(",");

  function overlaps(a, b) {
    return Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left))
      * Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
  }

  function collisionTargets() {
    return Array.prototype.filter.call(document.querySelectorAll(COLLISION_SELECTOR), function (element) {
      if (root.contains(element)) return false;
      var rect = element.getBoundingClientRect();
      var style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight
        && style.display !== "none" && style.visibility !== "hidden" && Number(style.opacity || 1) > 0;
    }).map(function (element) { return element.getBoundingClientRect(); });
  }

  function applyLauncherPosition(candidate) {
    root.style.top = "auto";
    root.style.bottom = candidate.bottom + "px";
    root.style.left = candidate.side === "left" ? candidate.edge + "px" : "auto";
    root.style.right = candidate.side === "right" ? candidate.edge + "px" : "auto";
  }

  function setLauncherAvailable(available) {
    root.classList.toggle("collision-hidden", !available);
    if (!available) {
      btn.setAttribute("aria-hidden", "true");
      btn.tabIndex = -1;
    } else if (!root.classList.contains("open")) {
      btn.removeAttribute("aria-hidden");
      btn.removeAttribute("tabindex");
    }
  }

  function placeLauncher() {
    placementFrame = 0;
    if (!mounted || root.classList.contains("open")) return;
    var rect = btn.getBoundingClientRect();
    if (!rect.width || !rect.height) return;
    var edge = innerWidth <= 500 ? 12 : 20;
    var step = Math.max(68, rect.height + 16);
    var targets = collisionTargets();
    var candidates = [];
    ["right", "left"].forEach(function (side) {
      for (var offset = 0; offset <= step * 4; offset += step) {
        candidates.push({ side: side, edge: edge, bottom: edge + offset });
      }
    });
    var best = candidates[0];
    var bestScore = Infinity;
    var clear = candidates.some(function (candidate) {
      var left = candidate.side === "right" ? innerWidth - candidate.edge - rect.width : candidate.edge;
      var top = innerHeight - candidate.bottom - rect.height;
      if (top < 72) return false;
      var proposed = { left: left, right: left + rect.width, top: top, bottom: top + rect.height };
      var score = targets.reduce(function (sum, target) { return sum + overlaps(proposed, target); }, 0);
      if (score < bestScore) { best = candidate; bestScore = score; }
      return score <= 4;
    });
    applyLauncherPosition(best);
    setLauncherAvailable(clear);
  }

  function scheduleLauncherPlacement() {
    if (placementFrame || root.classList.contains("open")) return;
    placementFrame = requestAnimationFrame(placeLauncher);
  }

  function placeOpenPanel() {
    setLauncherAvailable(true);
    root.style.top = "auto";
    root.style.bottom = (innerWidth <= 500 ? 12 : 20) + "px";
    root.style.left = innerWidth <= 500 ? "12px" : "auto";
    root.style.right = innerWidth <= 500 ? "12px" : "20px";
  }

  addEventListener("scroll", scheduleLauncherPlacement, { passive: true });
  addEventListener("resize", function () {
    if (root.classList.contains("open")) placeOpenPanel();
    else scheduleLauncherPlacement();
  }, { passive: true });
  setTimeout(scheduleLauncherPlacement, 0);
  setTimeout(scheduleLauncherPlacement, 500);
  setTimeout(scheduleLauncherPlacement, 2000);

  function makePageInert() {
    inertedSiblings = [];
    Array.prototype.forEach.call(document.body.children, function (child) {
      if (child === root || child.hasAttribute("inert")) return;
      child.setAttribute("inert", "");
      inertedSiblings.push(child);
    });
  }

  function restorePage() {
    inertedSiblings.forEach(function (child) {
      child.removeAttribute("inert");
    });
    inertedSiblings = [];
  }

  function focusableElements() {
    return Array.prototype.filter.call(
      panel.querySelectorAll('a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])'),
      function (el) { return el.getClientRects().length > 0 && el.getAttribute("aria-hidden") !== "true"; }
    );
  }

  /** One transcript row: a small letterspaced label above the text. */
  function row(kind, label, text) {
    var el = document.createElement("div");
    el.className = "bl-sup-row bl-sup-" + kind;
    var l = document.createElement("div");
    l.className = "bl-sup-lbl";
    l.textContent = label;
    var t = document.createElement("div");
    t.className = "bl-sup-txt";
    t.textContent = text;
    el.appendChild(l);
    el.appendChild(t);
    log.appendChild(el);
    log.scrollTop = log.scrollHeight;
    return t;
  }

  function open() {
    if (root.classList.contains("open")) return;
    previousFocus = document.activeElement;
    placeOpenPanel();
    root.classList.add("open");
    btn.setAttribute("aria-expanded", "true");
    btn.setAttribute("aria-hidden", "true");
    btn.disabled = true;
    btn.tabIndex = -1;
    panel.setAttribute("aria-hidden", "false");
    makePageInert();
    if (!log.childElementCount) row("a", BRAND, GREETING);
    setTimeout(function () {
      if (root.classList.contains("open")) input.focus();
    }, 60);
  }
  function close() {
    if (!root.classList.contains("open")) return;
    root.classList.remove("open");
    btn.setAttribute("aria-expanded", "false");
    panel.setAttribute("aria-hidden", "true");
    restorePage();
    btn.removeAttribute("aria-hidden");
    btn.disabled = false;
    btn.removeAttribute("tabindex");
    scheduleLauncherPlacement();
    var returnTarget = previousFocus && previousFocus.isConnected
      && previousFocus !== document.body && previousFocus !== document.documentElement
      && !previousFocus.matches('[disabled],[aria-hidden="true"],[inert]')
      ? previousFocus : btn;
    previousFocus = null;
    if (returnTarget && typeof returnTarget.focus === "function") returnTarget.focus();
  }

  btn.addEventListener("click", open);
  closeBtn.addEventListener("click", close);
  document.addEventListener("keydown", function (e) {
    if (!root.classList.contains("open")) return;
    if (e.key === "Escape") {
      e.preventDefault();
      close();
      return;
    }
    if (e.key !== "Tab") return;
    var items = focusableElements();
    if (!items.length) {
      e.preventDefault();
      panel.focus();
      return;
    }
    var first = items[0];
    var last = items[items.length - 1];
    var active = document.activeElement;
    if (!panel.contains(active)) {
      e.preventDefault();
      first.focus();
    } else if (e.shiftKey && active === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && active === last) {
      e.preventDefault();
      first.focus();
    }
  });

  input.addEventListener("input", function () {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 98) + "px";
    // The only affordance on the composer: the return mark warms when there is
    // something to send. No filled button competing with the page's own CTAs.
    var hasText = input.value.trim().length > 0;
    send.classList.toggle("on", hasText);
    send.disabled = busy || !hasText;
  });
  // Enter sends. Call the sender DIRECTLY rather than dispatching a synthetic
  // "submit" — a fabricated submit event is untrusted and does not reliably run
  // the form's submit path across browsers.
  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submitQuestion();
    }
  });

  var busy = false;
  form.addEventListener("submit", function (e) {
    e.preventDefault();
    submitQuestion();
  });

  function submitQuestion() {
    if (busy) return;
    var q = input.value.trim();
    if (!q) return;

    row("q", "You", q);
    input.value = "";
    input.style.height = "auto";
    send.classList.remove("on");
    busy = true;
    send.disabled = true;
    log.setAttribute("aria-busy", "true");

    var slot = row("a", BRAND, "");
    slot.innerHTML = '<span class="bl-sup-sr">Support is preparing a response.</span>' +
      '<span class="bl-sup-dots" aria-hidden="true"><i></i><i></i><i></i></span>';

    fetch(ENDPOINT, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ question: q }),
    })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        slot.innerHTML = "";
        slot.textContent = d && d.answer ? d.answer : "Something went wrong on our side.";
        if (d && d.answered && d.sources && d.sources.length) {
          var s = document.createElement("div");
          s.className = "bl-sup-src";
          s.innerHTML = "<b>Source</b>" + esc(d.sources.slice(0, 3).join(" · "));
          slot.appendChild(s);
        } else if (d && d.answered && d.general) {
          // Answered from general knowledge rather than this site's pages. Say so,
          // so a general fact can never be mistaken for a claim about the product.
          var g = document.createElement("div");
          g.className = "bl-sup-src";
          g.innerHTML = "<b>General</b>Not specific to " + esc(BRAND);
          slot.appendChild(g);
        }
        if (d && (!d.answered || d.route)) {
          var a = document.createElement("a");
          a.className = "bl-sup-esc";
          a.href = safeUrl(d && d.escalation, LINK_SCHEMES, ESCALATION);
          a.textContent = "Talk to a human";
          slot.appendChild(a);
        }
        log.scrollTop = log.scrollHeight;
      })
      .catch(function () {
        slot.innerHTML = "";
        slot.textContent = "I couldn't reach support just now. Please try again in a moment.";
        var a = document.createElement("a");
        a.className = "bl-sup-esc";
        a.href = ESCALATION;
        a.textContent = "Talk to a human";
        slot.appendChild(a);
      })
      .finally(function () {
        busy = false;
        log.setAttribute("aria-busy", "false");
        var hasText = input.value.trim().length > 0;
        send.disabled = !hasText;
        send.classList.toggle("on", hasText);
        if (root.classList.contains("open")) input.focus();
      });
  }
})();
