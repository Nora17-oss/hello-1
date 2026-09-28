#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
DEVELOPER="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
if [[ -d "$FRAMEWORKS/Testing.framework" ]]; then
    # CLT ships Testing but can omit the Foundation cross-import overlay module.
    swift test --disable-xctest \
        -Xswiftc "-F$FRAMEWORKS" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
    swift test "$@"
fi
