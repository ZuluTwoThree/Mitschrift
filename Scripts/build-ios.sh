#!/bin/zsh
# Erzeugt das Xcode-Projekt aus ios/project.yml und baut die iOS-App.
#   zsh Scripts/build-ios.sh                → Simulator-Build (Ad-hoc-Signatur, kein Team nötig)
#   zsh Scripts/build-ios.sh device [UDID]  → Geräte-Build; braucht ios/Local.xcconfig mit DEVELOPMENT_TEAM.
#                                             Mit UDID des angeschlossenen iPhones (xcrun devicectl list devices)
#                                             darf Xcode das Gerät im Team registrieren.
# Das vollständige xcodebuild-Log liegt danach in .build/ios-xcodebuild.log. Der Exitstatus von
# xcodebuild wird durchgereicht.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
IOS_DIR="$PROJECT_DIR/ios"
MODE="${1:-simulator}"
DEVICE_ID="${2:-}"
LOG="$PROJECT_DIR/.build/ios-xcodebuild.log"

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen" >&2; exit 1; }
[[ -f "$IOS_DIR/Local.xcconfig" ]] || : > "$IOS_DIR/Local.xcconfig"
mkdir -p "$PROJECT_DIR/.build"

(cd "$IOS_DIR" && xcodegen generate --quiet)

typeset -a EXTRA
case "$MODE" in
  simulator)
    DESTINATION='generic/platform=iOS Simulator'
    EXTRA=()
    ;;
  device)
    if [[ -n "$DEVICE_ID" ]]; then
      DESTINATION="platform=iOS,id=$DEVICE_ID"
    else
      DESTINATION='generic/platform=iOS'
    fi
    EXTRA=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
    ;;
  *)
    echo "Unbekannter Modus: $MODE (simulator|device)" >&2
    exit 1
    ;;
esac

set +e
xcodebuild \
  -project "$IOS_DIR/Mitschrift.xcodeproj" \
  -scheme Mitschrift-iOS \
  -destination "$DESTINATION" \
  -derivedDataPath "$PROJECT_DIR/.build/ios" \
  "${EXTRA[@]}" \
  build > "$LOG" 2>&1
STATUS=$?
set -e

if [[ "$STATUS" -eq 0 ]]; then
  grep -E "warning: |BUILD" "$LOG" | grep -v appintentsmetadataprocessor || true
else
  grep -E "error:|error |BUILD" "$LOG" | head -40 >&2
  echo "Vollständiges Log: $LOG" >&2
fi
exit "$STATUS"
