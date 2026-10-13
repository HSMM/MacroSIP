#!/usr/bin/env bash
# Checks that every key used in Sources/MacroSIPApp/Model/Strings.swift exists in
# Resources/{en,ru}.lproj (Localizable.strings or Localizable.stringsdict), that no file has
# keys the code does not use, and that the Russian value has no placeholders English lacks.
# Usage: scripts/check-strings.sh
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -I - <<'PY'
import re, plistlib, sys
root = "Sources/MacroSIPApp/Resources"
code = set(re.findall(r'loc\("([^"]+)"', open("Sources/MacroSIPApp/Model/Strings.swift", encoding="utf-8").read()))
def strings(path):
    d = {}
    for m in re.finditer(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$', open(path, encoding="utf-8").read(), re.M):
        d[m.group(1)] = m.group(2)
    return d
def plural(path):
    return plistlib.load(open(path, "rb"))
files = {}
for lang in ("en", "ru"):
    s = strings(f"{root}/{lang}.lproj/Localizable.strings")
    p = plural(f"{root}/{lang}.lproj/Localizable.stringsdict")
    files[lang] = (s, p)
bad = 0
def ph(v): return sorted(re.findall(r'%(?:\d+\$)?(?:lld|@|d)', v))
for lang, (s, p) in files.items():
    have = set(s) | set(p)
    for k in sorted(code - have): print(f"{lang}: missing key {k}"); bad += 1
    for k in sorted(have - code): print(f"{lang}: unused key {k}"); bad += 1
    for k in set(s) & set(p): print(f"{lang}: key {k} in both .strings and .stringsdict"); bad += 1
    for k, v in p.items():
        need = {"one", "few", "many", "other"} if lang == "ru" else {"one", "other"}
        got = set(v["count"]) - {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}
        if got != need: print(f"{lang}: {k} plural categories {sorted(got)} != {sorted(need)}"); bad += 1
en_s = files["en"][0]
norm = lambda l: [re.sub(r'\d+\$', '', x) for x in l]
for k, v in files["ru"][0].items():
    if k in en_s and not set(norm(ph(v))) <= set(norm(ph(en_s[k]))):
        print(f"ru: {k} uses placeholders English lacks"); bad += 1
print(f"{len(code)} keys checked, {bad} problem(s)")
sys.exit(1 if bad else 0)
PY
