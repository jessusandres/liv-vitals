#!/usr/bin/env python3
"""Adds the English singular forms to LivVitals/Localizable.xcstrings (the "other" form is the key itself).

Run after scripts/sync-strings.sh. Idempotent. A translator adds more plural categories in Xcode."""
import json
import pathlib

PATH = pathlib.Path(__file__).resolve().parent.parent / "LivVitals" / "Localizable.xcstrings"
ONE = {
    "%@ · %lld items": "%@ · %lld item",
    "%@, %lld items": "%@, %lld item",
    "%lld admin tasks need your password, asked once.": "%lld admin task needs your password, asked once.",
    "%lld admin tasks run without a password.": "%lld admin task runs without a password.",
    "%lld ask for your password.": "%lld asks for your password.",
    "%lld items": "%lld item",
    "%lld items (%@) are deleted permanently and cannot be recovered.": "%lld item (%@) is deleted permanently and cannot be recovered.",
    "%lld items (%@) move to the Trash.": "%lld item (%@) moves to the Trash.",
    "%lld items cleaned": "%lld item cleaned",
    "%lld items could not be read, so the totals may be low.": "%lld item could not be read, so the totals may be low.",
    "%lld items need your administrator password, asked once.": "%lld item needs your administrator password, asked once.",
    "%lld items put back": "%lld item put back",
    "%lld items start by themselves. Liv Vitals only shows them.": "%lld item starts by itself. Liv Vitals only shows them.",
    "%lld items stay where they are.": "%lld item stays where it is.",
    "%lld items · %@": "%lld item · %@",
    "%lld locations need Full Disk Access, so they were not scanned.": "%lld location needs Full Disk Access, so it was not scanned.",
    "%lld maintenance tasks run after the cleaning.": "%lld maintenance task runs after the cleaning.",
    "%lld maintenance tasks run.": "%lld maintenance task runs.",
    "%lld of them need your administrator password, asked once.": "%lld of them needs your administrator password, asked once.",
    "%lld of them point to programs that are gone.": "%lld of them points to a program that is gone.",
    "%lld tasks": "%lld task",
    "%lld tasks done": "%lld task done",
    "Put %lld items back?": "Put %lld item back?",
    "Put back %lld items from %@": "Put back %lld item from %@",
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


catalog = json.loads(PATH.read_text())
missing = [key for key in ONE if key not in catalog["strings"]]
for key, singular in ONE.items():
    if key in catalog["strings"]:
        catalog["strings"][key]["localizations"] = {
            "en": {"variations": {"plural": {"one": unit(singular), "other": unit(key)}}}
        }
PATH.write_text(json.dumps(catalog, indent=2, ensure_ascii=False, separators=(",", " : ")) + "\n")
print(f"plural forms set for {len(ONE) - len(missing)} strings")
for key in missing:
    print("  not in the catalog:", key)
