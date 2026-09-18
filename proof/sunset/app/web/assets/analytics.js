/* Funnel analytics — PostHog (project 452541), live since 2026-07-01 (DEM-1).
 * Captures page views + checkout-click intents so view→click→purchase conversion is
 * computable. Internal/automated traffic is tagged OUT so e2e verifiers and our own
 * sessions never pollute the funnel:
 *   - once:  visit any page with ?internal=1  (sticky via localStorage)
 *   - e2e:   scripts/e2e_verify.py appends ?internal=1 to every fetch
 *   - headless (navigator.webdriver) is dropped automatically
 */
(function () {
  "use strict";

  var PH_TOKEN = "phc_s3fBdVNLuuao2cA9XkA3EMoZ5iLusCWHZzZQWudYW2jo";
  var PH_HOST = "https://us.i.posthog.com";

  // ---- internal-traffic tag-out ------------------------------------------------
  // Only the public Sunset hosts contribute to the customer funnel. Preview
  // builds must stay quiet even when browser automation has no webdriver flag.
  var internal = !/^(www\.)?sunsetmixing\.com$/.test(location.hostname) ||
    new URLSearchParams(location.search).get("internal") === "1" ||
    navigator.webdriver === true ||
    navigator.doNotTrack === "1" ||
    window.doNotTrack === "1" ||
    navigator.globalPrivacyControl === true;
  try {
    if (new URLSearchParams(location.search).get("internal") === "1") {
      localStorage.setItem("blb_internal", "1");
    }
    internal = internal || localStorage.getItem("blb_internal") === "1" || localStorage.getItem("blb_analytics_opt_out") === "1";
  } catch (e) {}

  // ---- local funnel buffer (kept — free debugging, works even if PostHog is blocked)
  window.__funnel = window.__funnel || [];
  function track(event, detail) {
    try { if (localStorage.getItem("blb_analytics_opt_out") === "1") return; } catch (e) {}
    var rec = { event: event, detail: detail || {}, t: Date.now(), path: location.pathname };
    window.__funnel.push(rec);
    if (!internal && window.posthog && typeof window.posthog.capture === "function") {
      try { window.posthog.capture(event, rec.detail); } catch (e) {}
    }
  }

  // ---- PostHog loader (official snippet, trimmed) — skipped entirely for internal traffic
  if (!internal) {
    !(function (t, e) {
      var o, n, p, r;
      e.__SV || ((window.posthog = e), (e._i = []), (e.init = function (i, s, a) {
        function g(t, e) { var o = e.split("."); 2 == o.length && ((t = t[o[0]]), (e = o[1])), (t[e] = function () { t.push([e].concat(Array.prototype.slice.call(arguments, 0))); }); }
        ((p = t.createElement("script")).type = "text/javascript"), (p.crossOrigin = "anonymous"), (p.async = !0),
        (p.src = s.api_host + "/static/array.js"),
        (r = t.getElementsByTagName("script")[0]).parentNode.insertBefore(p, r);
        var u = e; for (void 0 !== a ? (u = e[a] = []) : (a = "posthog"), u.people = u.people || [], u.toString = function (t) { var e = "posthog"; return "posthog" !== a && (e += "." + a), t || (e += " (stub)"), e; }, u.people.toString = function () { return u.toString(1) + ".people (stub)"; }, o = "init capture register register_once unregister opt_out_capturing has_opted_out_capturing opt_in_capturing reset".split(" "), n = 0; n < o.length; n++) g(u, o[n]);
        e._i.push([i, s, a]);
      }), (e.__SV = 1));
    })(document, window.posthog || []);
    window.posthog.init(PH_TOKEN, {
      api_host: PH_HOST,
      capture_pageview: true,
      capture_pageleave: true,
      persistence: "localStorage",
      autocapture: false,
      disable_session_recording: true,
      person_profiles: "never",
      respect_dnt: true,
    });
  }

  // ---- checkout-intent funnel events ------------------------------------------
  function checkoutDestination(el) {
    if (!el || !el.getAttribute) return "";
    var href = el.getAttribute("href");
    if (!href) return "";
    try {
      var url = new URL(href, location.href);
      if (url.protocol !== "https:") return "";
      if (url.hostname === "buy.stripe.com" ||
          (url.origin === location.origin && /^\/buy\/?$/.test(url.pathname))) {
        // Never send query strings: payment URLs may contain attribution or
        // customer details. The click handler never edits or delays navigation.
        return url.origin + url.pathname;
      }
    } catch (e) {}
    return "";
  }

  document.addEventListener("click", function (e) {
    var el = e.target;
    for (; el && el !== document; el = el.parentElement) {
      var destination = checkoutDestination(el);
      if (destination) {
        track("checkout_click", {
          plan: el.getAttribute("data-stripe") || el.getAttribute("data-plan") || "",
          href: destination,
          site: "sunsetmixing.com",
          release: "20260914.checkout-measurement",
        });
        break;
      }
    }
  }, true);

  // Page-view funnel marker (posthog also auto-captures $pageview; this one carries referrer
  // into the local buffer and stays comparable with the pre-PostHog data shape).
  track("page_view", { ref: document.referrer || "" });
})();
