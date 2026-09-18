/**
 * depth-kit loader — applies the hardware treatment from a per-lane map.
 *
 * Reads its configuration from its own <script> tag:
 *   data-hw-accent   brand accent color (hex)
 *   data-hw-map      JSON: { role: "css,selectors" } for roles
 *                    panel | bolted | key | etch | seam | led | screen
 *   data-hw-flags    comma list: chassis, rails, grain, keystrong
 *
 * Pure progressive enhancement, same contract as blb-live.js: every page reads
 * fully without this file. It only adds classes and three inert fixed layers.
 * It never touches the support widget (.bl-sup*), never sets layout properties,
 * and caps how much it classifies so a runaway selector cannot decorate an
 * entire page (MAX_PER_ROLE).
 */
(function () {
  "use strict";

  var script = document.currentScript;
  if (!script) {
    var tags = document.querySelectorAll("script[data-hw-map]");
    script = tags[tags.length - 1];
  }
  if (!script) return;

  var MAX_PER_ROLE = 160;

  var map;
  try {
    map = JSON.parse(script.getAttribute("data-hw-map") || "{}");
  } catch (e) {
    map = {};
  }
  var flags = (script.getAttribute("data-hw-flags") || "").split(",");
  var accent = script.getAttribute("data-hw-accent") || "";

  function has(f) {
    return flags.indexOf(f) !== -1;
  }

  function apply() {
    var root = document.documentElement;
    root.setAttribute("data-hw", "1");
    if (has("keystrong")) root.setAttribute("data-hw-keystrong", "1");
    if (accent) root.style.setProperty("--hw-accent", accent);

    // Inert fixed layers. Chassis first so it sits lowest in source order.
    if (has("chassis") && !document.querySelector(".hw-chassis")) {
      var chassis = document.createElement("div");
      chassis.className = "hw-chassis";
      chassis.setAttribute("aria-hidden", "true");
      document.body.appendChild(chassis);
    }
    if (has("rails") && !document.querySelector(".hw-rail")) {
      ["hw-rail hw-rail--l", "hw-rail hw-rail--r"].forEach(function (cls) {
        var rail = document.createElement("div");
        rail.className = cls;
        rail.setAttribute("aria-hidden", "true");
        document.body.appendChild(rail);
      });
    }
    if (has("grain") && !document.querySelector(".hw-grain")) {
      var grain = document.createElement("div");
      grain.className = "hw-grain";
      grain.setAttribute("aria-hidden", "true");
      document.body.appendChild(grain);
    }

    // Role classes from the lane map. Never inside the support widget.
    var roleClass = {
      panel: "hw-panel",
      bolted: "hw-panel hw-panel--bolted",
      key: "hw-key",
      etch: "hw-etch",
      seam: "hw-seam",
      screen: "hw-screen",
    };
    Object.keys(roleClass).forEach(function (role) {
      var sel = map[role];
      if (!sel) return;
      var nodes;
      try {
        nodes = document.querySelectorAll(sel);
      } catch (e) {
        return; // a bad selector disables that role, never the page
      }
      var n = Math.min(nodes.length, MAX_PER_ROLE);
      for (var i = 0; i < n; i++) {
        var el = nodes[i];
        if (el.closest && el.closest(".bl-sup")) continue;
        roleClass[role].split(" ").forEach(function (c) {
          el.classList.add(c);
        });
        // The gradient keycap face only where the site painted no face of its
        // own — a background-image button (vigil's gold CTA) keeps its paint.
        if (role === "key" && has("keystrong")) {
          if (getComputedStyle(el).backgroundImage === "none") {
            el.classList.add("hw-key--face");
          }
        }
      }
    });

    // LEDs: insert our own <i> as first child — no pseudo-element collisions.
    if (map.led) {
      var leds;
      try {
        leds = document.querySelectorAll(map.led);
      } catch (e) {
        leds = [];
      }
      var m = Math.min(leds.length, MAX_PER_ROLE);
      for (var j = 0; j < m; j++) {
        var host = leds[j];
        if (host.closest && host.closest(".bl-sup")) continue;
        if (host.querySelector(":scope > .hw-led")) continue;
        var dot = document.createElement("i");
        dot.className = "hw-led";
        dot.setAttribute("aria-hidden", "true");
        host.insertBefore(dot, host.firstChild);
      }
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", apply);
  } else {
    apply();
  }
})();
