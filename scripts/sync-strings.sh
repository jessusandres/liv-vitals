#!/bin/zsh
# Brings LivVitals/Localizable.xcstrings up to date with the strings the last Debug and Release builds found, and
# lists what is stale. xcodebuild does not write the catalog back (Xcode does), so this does it with xcstringstool.
# Run `make build` and a Debug build first. Plural forms live in the catalog and survive a sync.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
catalog=LivVitals/Localizable.xcstrings
files=("${(@f)$(find build/Build/Intermediates.noindex/LivVitals.build/Debug -name '*.stringsdata')}")
xcrun xcstringstool sync "$catalog" --stringsdata $files
python3 - "$catalog" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1]))
stale = [key for key, value in catalog["strings"].items() if value.get("extractionState") == "stale"]
print(f"{len(catalog['strings'])} strings, {len(stale)} stale")
for key in stale:
    print("  stale:", key)
PY
