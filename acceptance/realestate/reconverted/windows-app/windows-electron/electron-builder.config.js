// Packaging for the Electron sibling shell.
//
// NSIS builds on macOS. APPX/MSIX does NOT — makeappx.exe is Windows-only, so the Store target
// has to run on a real Windows host or a windows-latest runner. Stated, never worked around.
//
// IDENTITY: this app's Store identity contract is the SAME ONE ../windows/build-msix.sh already
// uses — the three PARTNER_CENTER_* environment variables, with its placeholder strings treated
// as absent. (Academy keeps its equivalent in a committed .env file under different names; each
// app owns its own identity and they are deliberately not shared.) Values are assigned by
// Partner Center and do not exist until the account is verified, so the appx target refuses
// rather than emitting a package with an invented publisher.
const { join } = require("node:path");

// Verbatim from ../windows/build-msix.sh — if that file's defaults change, these must too.
const PLACEHOLDERS = [
  "PARTNER-CENTER-PLACEHOLDER",
  "__PARTNER_CENTER_PUBLISHER_DISPLAY_NAME__",
];

function readIdentity() {
  const values = {
    identityName: process.env.PARTNER_CENTER_IDENTITY_NAME || "",
    publisher: process.env.PARTNER_CENTER_IDENTITY_PUBLISHER || "",
    publisherDisplayName: process.env.PARTNER_CENTER_PUBLISHER_DISPLAY_NAME || "",
  };
  const unfilled = Object.entries(values)
    .filter(([, value]) => !value || PLACEHOLDERS.some((placeholder) => value.includes(placeholder)))
    .map(([key]) => key);
  return unfilled.length
    ? { ok: false, reason: `Partner Center identity not assigned yet: ${unfilled.join(", ")}` }
    : { ok: true, values };
}

const identity = readIdentity();
const wantsAppx = process.argv.some((argument) => argument.includes("appx"));
if (wantsAppx && !identity.ok) {
  throw new Error(`appx/MSIX refused — ${identity.reason}. The NSIS target still builds; only the Store package is gated.`);
}

module.exports = {
  appId: "com.blacklabel.realestate",
  productName: "Black Label Real Estate",
  // Own output tree. The Tauri lane's msix-layout/ is never touched — the two shells must be
  // comparable side by side, so neither may overwrite the other.
  directories: { output: "release" },
  files: ["main.js", "serve.js", "app/**", "package.json"],
  icon: join(__dirname, "..", "windows", "src-tauri", "icons", "icon.ico"),
  win: {
    target: ["nsis"],
    // No Authenticode cert exists (founder purchase gate), so nothing here signs. The artifact
    // name carries that fact rather than leaving it to a README.
    artifactName: "BlackLabelRealEstate-electron-${version}-UNSIGNED.${ext}",
  },
  nsis: { oneClick: true, perMachine: false, deleteAppDataOnUninstall: false },
  ...(identity.ok ? {
    appx: {
      identityName: identity.values.identityName,
      publisher: identity.values.publisher,
      publisherDisplayName: identity.values.publisherDisplayName,
      applicationId: "BlackLabelRealEstate",
      displayName: "Black Label Real Estate",
      backgroundColor: "#000000",
    },
  } : {}),
};
