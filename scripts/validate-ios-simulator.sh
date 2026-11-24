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

# Resolve large binary artifacts before booting the simulator. Retry transient
# GitHub release download timeouts instead of failing the whole validation job.
attempt=1
max_attempts=3
while true; do
  echo "Resolving Swift packages (attempt $attempt/$max_attempts)..." | tee -a "$LOG_DIR/package-resolution.log"
  if xcodebuild -resolvePackageDependencies -project STV.xcodeproj -scheme STV 2>&1 | tee -a "$LOG_DIR/package-resolution.log"; then
    break
  fi
  if (( attempt >= max_attempts )); then
    echo "Swift package resolution failed after $max_attempts attempts." >&2
    exit 1
  fi
  sleep $((attempt * 20))
  attempt=$((attempt + 1))
done

# Fresh GitHub runners may spend several minutes migrating the selected iOS
# runtime on first boot. Five minutes was too short; allow up to fifteen.
xcrun simctl boot "$SIM_ID" 2>&1 | tee "$LOG_DIR/simulator-boot.log" || true
python3 -c 'import subprocess,sys; subprocess.run(["xcrun","simctl","bootstatus",sys.argv[1],"-b"],check=True,timeout=900)' "$SIM_ID" 2>&1 | tee -a "$LOG_DIR/simulator-boot.log"

set -o pipefail
xcodebuild -project STV.xcodeproj -scheme STV -configuration Release \
  -destination "platform=iOS Simulator,id=$SIM_ID" -derivedDataPath DerivedDataValidation \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO ARCHS="$SIM_ARCH" ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES \
  -parallel-testing-enabled NO \
  -only-testing:STVTests/LegadoTests \
  -only-testing:STVTests/PluginTests/testCMSCategoryRequestsKeepFullCategoryList \
  -only-testing:STVTests/PluginTests/testMacCMSParsing \
  -only-testing:STVTests/PluginTests/testManifestValidation \
  -only-testing:STVTests/SiteParsingTests/testTubeHelpers \
  -only-testing:STVTests/CENCStreamTests \
  test 2>&1 | tee "$LOG_DIR/tests.log"
