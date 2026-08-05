#!/usr/bin/env bash
# Runs the integration suite with runtime permissions granted.
#
# WHY THIS SCRIPT EXISTS, because the obvious invocation hangs rather than
# fails and the reason is not guessable from the symptom.
#
# `flutter test integration_test` installs the app itself and UNINSTALLS it
# afterwards, so any `pm grant` done beforehand is discarded by that install.
# Without the grants, the rationale screen's CONTINUE raises a SYSTEM
# permission dialog. That dialog is outside the Flutter tree, so WidgetTester
# cannot tap it and the run does not fail — it sits on "ASKING…" until the
# timeout.
#
# The grants therefore have to land AFTER flutter's install and BEFORE the
# first test taps CONTINUE. A background loop retrying `pm grant` does exactly
# that: it fails harmlessly with "package not found" until the install
# completes, then succeeds.
#
# POST_NOTIFICATIONS matters as much as the location pair — the rationale
# screen asks for both, and either one left ungranted stalls the same way.
#
#   ./scripts/run-integration.sh [device]      default: emulator-5554
set -uo pipefail

DEVICE="${1:-emulator-5554}"
PKG=com.irallyclub.irallymeter
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"

if [ ! -x "$ADB" ]; then
  echo "adb not found at $ADB — set ADB=/path/to/adb" >&2
  exit 1
fi

(
  for _ in $(seq 1 240); do
    for p in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION POST_NOTIFICATIONS; do
      "$ADB" -s "$DEVICE" shell pm grant "$PKG" "android.permission.$p" >/dev/null 2>&1
    done
    sleep 0.5
  done
) &
GRANTER=$!
trap 'kill $GRANTER 2>/dev/null' EXIT

flutter test integration_test/app_flows_test.dart -d "$DEVICE"
