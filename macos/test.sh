#!/bin/bash
# Runs the unit tests (Swift Testing). With full Xcode `swift test` just works;
# with Command Line Tools alone the Testing framework has to be pointed at
# explicitly, which is what this wrapper does.
set -euo pipefail
cd "$(dirname "$0")"
CLT=/Library/Developer/CommandLineTools
if [ "$(xcode-select -p)" = "$CLT" ]; then
  F="$CLT/Library/Developer/Frameworks"
  INTEROP="$CLT/Library/Developer/usr/lib"
  exec swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$INTEROP" "$@"
else
  exec swift test --disable-xctest --enable-swift-testing "$@"
fi
