#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Some Command Line Tools releases omit the Testing macro plugin from discovery.
TEST_PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TEST_PLUGIN" ]]; then
  swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN"
else
  swift test --disable-xctest
fi
