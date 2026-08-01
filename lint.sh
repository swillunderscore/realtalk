#!/bin/bash
# Duplicate-definition lint. A partially duplicated class COMPILES under
# redscript and then crashes the game at runtime - this happened (chat-open
# CTD traced to a class with doubled members after layered patch surgery).
# Scoped per class; @if-gated conditional pairs are legitimate and skipped.
cd "$(dirname "$0")"
python3 - <<'PY'
import glob, re, sys
fail = 0
for path in sorted(glob.glob("r6/scripts/StreetTalk/*.reds")):
    lines = open(path).read().splitlines()
    cls, seen, gated = "", {}, False
    for i, ln in enumerate(lines):
        m = re.match(r"public (?:abstract )?class (\w+)", ln)
        if m:
            cls, gated = m.group(1), False
            continue
        # A method annotation retargets the following function onto ANOTHER
        # class - two @wrapMethod blocks for the same method name on different
        # classes are correct, and reading them as duplicates in whatever
        # class came last blocked a legitimate deploy.
        m = re.match(r"@(?:wrap|replace|add)Method\((\w+)\)", ln)
        if m:
            cls = m.group(1)
            continue
        if "@if(" in ln:
            gated = True
            continue
        m = re.search(r"(?:private|public)(?: final)?(?: static)?(?: cb)? func (\w+)\(", ln)
        if m:
            key = (cls, m.group(1))
            if not gated:
                seen.setdefault(key, 0)
                seen[key] += 1
            gated = False
    dups = [k for k, v in seen.items() if v > 1]
    if dups:
        fail = 1
        print(f"DUPLICATE FUNCS in {path}:")
        for c, f in dups:
            print(f"    {c}.{f}")
classes = {}
for path in sorted(glob.glob("r6/scripts/StreetTalk/*.reds")):
    for m in re.finditer(r"^public (?:abstract )?class (\w+)", open(path).read(), re.M):
        classes.setdefault(m.group(1), []).append(path)
for c, ps in classes.items():
    if len(ps) > 1:
        fail = 1
        print(f"DUPLICATE CLASS {c}: {ps}")
print("lint: clean" if not fail else "lint: FAIL")
sys.exit(fail)
PY
