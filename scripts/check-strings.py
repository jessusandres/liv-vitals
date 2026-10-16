#!/usr/bin/env python3
"""Checks LivVitals/Localizable.xcstrings for the defects that break a screen or hide a string.

For every key: no entry or translation unit is stale or empty; every plural (or device) variation uses the same
format specifiers as the key; and every plural variation of a count still contains its number.
Exits with 1 and lists every problem. `make check-strings` runs it, and `make strings` runs it after the sync.
The same rules are checked by LivVitalsTests/LocalizationCatalogTests.swift."""
import json
import pathlib
import re
import sys

CATALOG = pathlib.Path(__file__).resolve().parent.parent / "LivVitals" / "Localizable.xcstrings"
# A format specifier such as %@, %d, %lld, %.1f or %1$@. A literal "%%" is removed first.
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ 0#]*(?:\d+|\*)?(?:\.\d+)?(?:hh|h|ll|l|L|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaF]")
# The "2$" in %2$@, which picks the argument by its place.
POSITION = re.compile(r"^%(\d+)\$")
# The specifiers that print a whole number, which is where a count goes.
COUNT = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:hh|h|ll|l|L|q|z|t|j)?[dDuUoxX]")


def specifiers(text):
    """The argument types in order-free form: %2$@ and %@ both count as %@, so a translation may reorder them."""
    return sorted(POSITION.sub("%", spec) for spec in SPECIFIER.findall(text.replace("%%", "")))


def positions_are_complete(text):
    """Explicit positions (%2$@) must be exactly 1 to N, each used, and never mixed with plain ones."""
    found = SPECIFIER.findall(text.replace("%%", ""))
    numbered = [int(match.group(1)) for spec in found if (match := POSITION.match(spec))]
    if not numbered:
        return True
    return len(numbered) == len(found) and sorted(set(numbered)) == list(range(1, len(found) + 1))


def units(localization, path=()):
    """Every (path, unit) under a localization, through plural and device variations."""
    if "stringUnit" in localization:
        yield path, localization["stringUnit"]
    for kind, cases in localization.get("variations", {}).items():
        for case, body in cases.items():
            yield from units(body, path + (kind, case))


def problems_in(catalog):
    found = []
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale":
            found.append(f"{key!r}: the key is stale")
        expected = specifiers(key)
        for locale, localization in entry.get("localizations", {}).items():
            for path, unit in units(localization):
                where = f"{key!r} [{locale}{''.join(f' {kind} {case}' for kind, case in zip(path[::2], path[1::2]))}]"
                value = unit.get("value", "")
                if not value.strip():
                    found.append(f"{where}: the translation is empty")
                if unit.get("state") == "stale":
                    found.append(f"{where}: the translation is stale")
                if specifiers(value) != expected:
                    found.append(f"{where}: specifiers {specifiers(value)} differ from the key's {expected}")
                if not positions_are_complete(value):
                    found.append(f"{where}: explicit argument positions are not 1 to N, each used once")
                if path[:1] == ("plural",) and not COUNT.search(value):
                    found.append(f"{where}: this plural form does not show its number")
    return found


def main():
    catalog = json.loads(CATALOG.read_text())
    found = problems_in(catalog)
    if found:
        print(f"{CATALOG.name}: {len(found)} problem(s)", file=sys.stderr)
        for line in found:
            print(f"  {line}", file=sys.stderr)
        sys.exit(1)
    plurals = sum(1 for entry in catalog["strings"].values() if "variations" in entry.get("localizations", {}).get("en", {}))
    print(f"{CATALOG.name}: {len(catalog['strings'])} strings ({plurals} with plural forms) pass the checks")


if __name__ == "__main__":
    main()
