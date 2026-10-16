#!/bin/zsh
# CPU and memory cost of a Liv Vitals screen, read-only (Stage 10.B). Builds Release with the probe compiled in, opens the
# given module (default: monitor), lets it settle, then prints `top -pid` CPU samples (percent of ONE core) and the physical
# footprint. Usage: scripts/monitor-cpu-probe.sh [module] [samples] [indicators]
# `indicators` is a comma list (cpu,memory,gpu,disk,diskActivity,network,battery) shown in the menu bar for this launch only
# (-LivIndicators; nothing is saved).
# Quit the installed LivVitals and Device Monitor first so they do not add their own load.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
module=${1:-monitor}
samples=${2:-15}
indicators=${3:-}
xcodebuild -project LivVitals.xcodeproj -scheme LivVitals -configuration Release -derivedDataPath build/perf \
  -allowProvisioningUpdates OTHER_SWIFT_FLAGS='$(inherited) -DPERF_PROBE' build -quiet
binary="build/perf/Build/Products/Release/LivVitals.app/Contents/MacOS/LivVitals"
if [[ -n $indicators ]]; then "$binary" -LivStartModule "$module" -LivIndicators "$indicators" & else "$binary" -LivStartModule "$module" & fi
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep 8
cpu=$(top -pid $pid -l $samples -s 1 -stats pid,cpu | awk -v p=$pid '$1 == p { printf "%s ", $2 }')
footprint=$(vmmap -summary $pid 2>/dev/null | awk '/^Physical footprint:/ { print $3 }')
children=$(pgrep -P $pid -x top >/dev/null && echo yes || echo no)
echo "module=$module indicators=${indicators:-none} cpu%=[ $cpu] footprint=$footprint top-child=$children"
echo "$cpu" | awk '{ n = 0; s = 0; for (i = 2; i <= NF; i++) { s += $i; n++ } if (n) printf "mean (first sample dropped): %.1f%% of one core\n", s / n }'
