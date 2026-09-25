#!/usr/bin/env bash

# Refuse unsigned/ad-hoc, same-build, and downgrade replacements of the
# canonical Circuit installation. Rollbacks require an explicit founder-owned
# override and still require a valid Developer ID signature.
production_install_guard() {
  local candidate_bundle="${1:-}"
  local installed_bundle="${2:-}"
  local allow_nonmonotonic="${3:-0}"
  local signature=""
  local candidate_build=""
  local installed_build=""

  case "$allow_nonmonotonic" in
    0|1) ;;
    *)
      echo "ABORT: BLB_ALLOW_NONMONOTONIC_INSTALL must be exactly 0 or 1." >&2
      return 66
      ;;
  esac

  if [[ -z "$candidate_bundle" || ! -d "$candidate_bundle" ]]; then
    echo "ABORT: release bundle is missing: $candidate_bundle" >&2
    return 65
  fi
  if ! signature="$(codesign -dvvv "$candidate_bundle" 2>&1)"; then
    echo "ABORT: release bundle signature could not be inspected: $candidate_bundle" >&2
    return 65
  fi
  if [[ "$signature" == *"Signature=adhoc"* ]] ||
     [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
    echo "ABORT: /Applications install requires a Developer ID Application signature." >&2
    return 65
  fi

  [[ -d "$installed_bundle" ]] || return 0
  candidate_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$candidate_bundle/Contents/Info.plist" 2>/dev/null || true)"
  installed_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$installed_bundle/Contents/Info.plist" 2>/dev/null || true)"
  if [[ ! "$candidate_build" =~ ^[0-9]+$ || ! "$installed_build" =~ ^[0-9]+$ ]]; then
    echo "ABORT: release build numbers must be numeric (candidate=$candidate_build installed=$installed_build)." >&2
    return 66
  fi
  if (( candidate_build <= installed_build )) && [[ "$allow_nonmonotonic" != "1" ]]; then
    echo "ABORT: candidate build $candidate_build must be newer than installed build $installed_build." >&2
    echo "       Founder-directed rollback only: BLB_ALLOW_NONMONOTONIC_INSTALL=1." >&2
    return 66
  fi
}
