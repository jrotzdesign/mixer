#!/bin/zsh
# Runs the unit tests; prints failures and the final summary line. Exit code follows xcodebuild.
cd ${0:A:h:h}
LOG=build/test.log
mkdir -p build
xcodebuild test -project Mixer.xcodeproj -scheme Mixer -derivedDataPath build/DerivedData -destination 'platform=macOS' "$@" > $LOG 2>&1
STATUS=$?
grep -E "^/.*error:|: error -\[|failed \(" $LOG | head -20
grep -E "Executed [0-9]+ tests" $LOG | tail -1 | sed 's/^[[:space:]]*//'
grep -E "\*\* TEST (SUCCEEDED|FAILED) \*\*|\*\* BUILD FAILED \*\*" $LOG | tail -1
exit $STATUS
