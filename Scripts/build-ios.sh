#!/bin/zsh
# Erzeugt das Xcode-Projekt aus ios/project.yml und baut die iOS-App.
#   zsh Scripts/build-ios.sh            → Simulator-Build (Ad-hoc-Signatur, kein Team nötig)
#   zsh Scripts/build-ios.sh device     → Geräte-Build (braucht ios/Local.xcconfig mit DEVELOPMENT_TEAM)
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
IOS_DIR="$PROJECT_DIR/ios"
MODE="${1:-simulator}"

command -v xcodegen >/dev/null || { echo "xcodegen fehlt: brew install xcodegen" >&2; exit 1; }
[[ -f "$IOS_DIR/Local.xcconfig" ]] || : > "$IOS_DIR/Local.xcconfig"

(cd "$IOS_DIR" && xcodegen generate --quiet)

case "$MODE" in
  simulator)
    xcodebuild \
      -project "$IOS_DIR/Mitschrift.xcodeproj" \
      -scheme Mitschrift-iOS \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$PROJECT_DIR/.build/ios" \
      build | grep -E "error|warning: |BUILD" || true
    ;;
  device)
    xcodebuild \
      -project "$IOS_DIR/Mitschrift.xcodeproj" \
      -scheme Mitschrift-iOS \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$PROJECT_DIR/.build/ios" \
      -allowProvisioningUpdates \
      build | grep -E "error|warning: |BUILD" || true
    ;;
  *)
    echo "Unbekannter Modus: $MODE (simulator|device)" >&2; exit 1 ;;
esac
