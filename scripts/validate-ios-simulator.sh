#!/bin/bash
# Simulator-only regression validation. The IPA workflow builds and uploads the
# device package independently, so these checks never delay IPA availability.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG_DIR="${STV_BUILD_LOG_DIR:-$RUNNER_TEMP/ios-validation-logs}"
mkdir -p "$LOG_DIR"

xcodegen generate >/dev/null
SIM_ARCH=$(uname -m)
SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)
SIM_ID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
sdk=int(sys.argv[1].split(".")[0])
candidates=[]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-" not in runtime:
        continue
    version=tuple(map(int,runtime.split("iOS-")[-1].split("-")))
    for device in devices:
        if device["name"].startswith("iPhone") and version[0] == sdk:
            candidates.append((version,device["udid"]))
assert candidates, "No iPhone simulator compatible with the selected Xcode SDK"
print(max(candidates,key=lambda item:item[0])[1])
' "$SDK_VERSION")

echo "Testing with iOS Simulator SDK $SDK_VERSION on $SIM_ID" | tee "$LOG_DIR/environment.log"
xcrun simctl boot "$SIM_ID" || true
python3 -c 'import subprocess,sys; subprocess.run(["xcrun","simctl","bootstatus",sys.argv[1],"-b"],check=True,timeout=180)' "$SIM_ID"

set -o pipefail
xcodebuild -project STV.xcodeproj -scheme STV -configuration Release \
  -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath DerivedDataValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS="$SIM_ARCH" ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:STVTests/LegadoTests \
  -only-testing:STVTests/PluginTests/testCMSCategoryRequestsKeepFullCategoryList \
  -only-testing:STVTests/PluginTests/testMacCMSParsing \
  -only-testing:STVTests/PluginTests/testManifestValidation \
  -only-testing:STVTests/CENCStreamTests \
  test 2>&1 | tee "$LOG_DIR/tests.log"
