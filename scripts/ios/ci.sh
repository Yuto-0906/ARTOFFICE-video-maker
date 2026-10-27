#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
mkdir -p ios/build
git rev-parse HEAD > ios/build/revision.txt
swift scripts/ios/prepare-assets.swift
if [[ ! -x ios/build/xcodegen/bin/xcodegen ]]; then
  curl --fail --location --retry 3 'https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip' -o ios/build/xcodegen.zip
  unzip -q -o ios/build/xcodegen.zip -d ios/build
fi
GENERATOR="$TASK_ROOT/ios/build/xcodegen/bin/xcodegen"
"$GENERATOR" --version | tee ios/build/xcodegen-version.txt
"$GENERATOR" --version | grep -q '2.44.1'
"$GENERATOR" generate --spec ios/project.yml --project ios
xcodebuild -version | tee ios/build/xcode-version.txt
xcodebuild -help > ios/build/xcodebuild-help.log 2>&1
TEST_DIAGNOSTICS=()
if grep -q -- '-collect-test-diagnostics' ios/build/xcodebuild-help.log; then
  # Keep the xcresult，but avoid a ten-minute simulator diagnostic collection
  # blocking every failing test on the CI host.
  TEST_DIAGNOSTICS=(-collect-test-diagnostics never)
fi
if [[ "${1:-check}" == check ]]; then
  TEST_SELECTION=()
  case "${2:-all}" in
    all) ;;
    ui) TEST_SELECTION=(-only-testing:ARTOFFICEUITests/EditorUITests/testEditorNavigationAndSavedProjectSurviveRelaunch) ;;
    media) TEST_SELECTION=(-only-testing:ARTOFFICETests/RuntimePressureTests
                           -only-testing:ARTOFFICETests/MediaExportTests/testShortRelinkIsRejectedBeforeCopyingMedia
                           -only-testing:ARTOFFICETests/MediaExportTests/testOutputVolumeReadsRealFilesystemLimitWithoutWritingMedia
                           -only-testing:ARTOFFICETests/MediaExportTests/testTimelinePreviewUsesTrimmedTimelineAndDeviceRenderSize
                           -only-testing:ARTOFFICETests/MediaExportTests/testChunkReuseRejectsRedirectedAndInvalidCache
                           -only-testing:ARTOFFICETests/MediaExportTests/testCompletedCleanupPreservesSourcesChunksAndExternalFiles
                           -only-testing:ARTOFFICETests/MediaExportTests/testOutputFormatsPreserveFrameCountAndRate
                           -only-testing:ARTOFFICETests/MediaExportTests/testInterruptedAttemptDoesNotHideCommittedOutputs
                           -only-testing:ARTOFFICETests/MediaExportTests/testRotationMatchesAVFoundationReference
                           -only-testing:ARTOFFICETests/MediaExportTests/testChunkedExportMuxAndReuse) ;;
    storage) TEST_SELECTION=(-only-testing:ARTOFFICETests/MediaExportTests/testCompletedCleanupPreservesSourcesChunksAndExternalFiles
                             -only-testing:ARTOFFICETests/MediaExportTests/testOutputVolumeReadsRealFilesystemLimitWithoutWritingMedia
                             -only-testing:ARTOFFICETests/MediaExportTests/testChunkReuseRejectsRedirectedAndInvalidCache
                             -only-testing:ARTOFFICETests/MediaExportTests/testInterruptedAttemptDoesNotHideCommittedOutputs) ;;
    *) echo 'Unknown test selection' >&2; exit 2 ;;
  esac
  echo 'Running model and persistence tests'
  (cd ios && swift test) 2>&1 | tee ios/build/core-tests.log
  echo 'Building the physical-device target without signing'
  xcodebuild -project ios/ARTOFFICE.xcodeproj -scheme ARTOFFICE -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath ios/build/device CODE_SIGNING_ALLOWED=NO build \
    > ios/build/device-build.log 2>&1 || { grep -n -A 5 -B 2 -E 'error:|fatal error:|BUILD FAILED' ios/build/device-build.log || true; tail -n 35 ios/build/device-build.log; exit 1; }
  echo 'Compiling simulator tests before booting devices'
  xcodebuild -project ios/ARTOFFICE.xcodeproj -scheme ARTOFFICE -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/build/simulator CODE_SIGNING_ALLOWED=NO build-for-testing \
    > ios/build/simulator-build.log 2>&1 || { grep -n -A 5 -B 2 -E 'error:|fatal error:|BUILD FAILED' ios/build/simulator-build.log || true; tail -n 35 ios/build/simulator-build.log; exit 1; }
  xcrun simctl list devices available --json > ios/build/simulators.json
  OVERALL_RESULT=0
  for FAMILY in iPhone iPad; do
    echo "Running media and UI tests on $FAMILY"
    DEVICE_ID="$(python3 - "$FAMILY" <<'PY'
import json, sys
with open('ios/build/simulators.json') as source:
    devices = [(runtime, d) for runtime, values in json.load(source)['devices'].items() if 'iOS' in runtime for d in values if d.get('isAvailable') and sys.argv[1] in d['name']]
if not devices:
    raise SystemExit('No available ' + sys.argv[1] + ' simulator')
devices.sort(key=lambda pair: ('iOS-27-0' not in pair[0],
    ('15' if sys.argv[1] == 'iPhone' else 'M4') not in pair[1]['name'],
    sys.argv[1] == 'iPad' and '13' not in pair[1]['name'], pair[1]['name']))
print('Selected ' + devices[0][1]['name'] + ' / ' + devices[0][0], file=sys.stderr)
print(devices[0][1]['udid'])
PY
)"
    echo "Booting $FAMILY simulator"
    xcrun simctl boot "$DEVICE_ID" 2> "ios/build/${FAMILY}-boot.log" || true
    xcrun simctl bootstatus "$DEVICE_ID" -b
    TEST_RESULT=0
    xcodebuild -project ios/ARTOFFICE.xcodeproj -scheme ARTOFFICE -configuration Debug \
      -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath ios/build/simulator \
      -parallel-testing-enabled NO -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 600 \
      ${TEST_DIAGNOSTICS[@]+"${TEST_DIAGNOSTICS[@]}"} \
      ${TEST_SELECTION[@]+"${TEST_SELECTION[@]}"} \
      -resultBundlePath "ios/build/${FAMILY}.xcresult" CODE_SIGNING_ALLOWED=NO test-without-building \
      2>&1 | tee "ios/build/${FAMILY}-tests.log" | awk '/Test Case|Test Suite|ARTOFFICE AAC|ARTOFFICE export|ARTOFFICE test|ARTOFFICE UI|error:|failed|TEST FAILED|TEST SUCCEEDED|CoreSimulator|IDE.*(error|Error|timed out)|Testing started/ { print; fflush() }' \
      || TEST_RESULT=$?
    if [[ "$TEST_RESULT" != 0 ]]; then
      OVERALL_RESULT=1
      grep -n -A 5 -B 2 -E 'error:|failed|TEST FAILED' "ios/build/${FAMILY}-tests.log" || true
      tail -n 45 "ios/build/${FAMILY}-tests.log"
    fi
    if [[ -d "ios/build/${FAMILY}.xcresult" ]]; then
      xcrun xcresulttool export attachments --path "ios/build/${FAMILY}.xcresult" --output-path "ios/build/${FAMILY}-screenshots" \
        > "ios/build/${FAMILY}-attachments.log" 2>&1 || { cat "ios/build/${FAMILY}-attachments.log"; OVERALL_RESULT=1; }
    fi
    xcrun simctl shutdown "$DEVICE_ID" || true
    echo "$FAMILY test exit status: $TEST_RESULT"
  done
  if [[ "$OVERALL_RESULT" != 0 ]]; then exit 1; fi
elif [[ "${1:-}" == device ]]; then
  echo 'Running model and persistence tests before signing'
  (cd ios && swift test) 2>&1 | tee ios/build/core-tests.log
  python3 scripts/ios/sign.py
else
  echo 'Usage: ci.sh check [all|media|storage|ui]|device' >&2; exit 2
fi
