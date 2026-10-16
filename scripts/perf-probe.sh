#!/bin/zsh
# Times the three scans of Stage 9.C with the real services, read-only, from a Release build with the probe compiled in.
# Usage: scripts/perf-probe.sh            (builds into build/perf, runs every scenario)
#        scripts/perf-probe.sh spacelens  (one scenario)
# Each line: the probe's JSON (time, files, items, longest main-thread stall) and the peak memory from /usr/bin/time -l.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodebuild -project LivVitals.xcodeproj -scheme LivVitals -configuration Release -derivedDataPath build/perf \
  -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -DPERF_PROBE' build -quiet
binary="build/perf/Build/Products/Release/LivVitals.app/Contents/MacOS/LivVitals"
if (( $# )); then scenarios=($@); else scenarios=(cleanup smartcare spacelens uninstaller); fi
for scenario in $scenarios; do
  runs=1
  [[ $scenario == spacelens ]] && runs=2   # the second run is the warm-cache one
  /usr/bin/time -l "$binary" -LivPerfProbe "$scenario" -LivPerfRuns $runs 2>&1 \
    | grep -E '^\{|maximum resident set size|real' \
    | awk '/maximum resident set size/ { printf "{\"peakMemoryMB\":%d}\n", $1 / 1048576; next } { print }'
done
