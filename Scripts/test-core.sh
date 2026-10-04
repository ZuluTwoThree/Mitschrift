#!/bin/zsh
# Führt die MitschriftCore-Tests aus. Mit reinen Command Line Tools fehlt swift-testing im
# Standard-Suchpfad; dann werden die Frameworks aus den CLT ergänzt.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if xcode-select -p 2>/dev/null | grep -q "CommandLineTools"; then
  FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
  exec swift test -Xswiftc -F"$FRAMEWORKS" -Xlinker -F"$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays "$@"
else
  exec swift test "$@"
fi
