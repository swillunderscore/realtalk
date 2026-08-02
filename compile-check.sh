#!/bin/bash
# Full redscript compile of the DEPLOYED game scripts, exactly the set a real
# launch compiles: r6/scripts plus every RED4ext plugin's shipped .reds
# (mod_settings, ArchiveXL, Codeware, TweakXL - the same list visible in
# r6/logs/redscript_rCURRENT.log from a real launch).
#
# Exists because lint.sh only catches duplicate definitions: a syntax error
# (unescaped backslash in a resource literal, field-caught) or a bad type
# sails through lint and costs the user a whole game launch to discover.
#
# Wine pops scc's failure dialog on the desktop unless the display env is
# emptied - that stray dialog scared the user once. Headless, always.
set -u
# Your game directory. Set REALTALK_GAME_DIR in the environment (or in
# server/local.conf, which is machine-local and never committed) - no
# developer's own paths belong in a public repo.
GAME="${REALTALK_GAME_DIR:-}"
if [ -z "$GAME" ] && [ -f "$(dirname "$0")/server/local.conf" ]; then
    GAME=$(. "$(dirname "$0")/server/local.conf" 2>/dev/null; echo "$REALTALK_GAME_DIR")
fi
if [ -z "$GAME" ]; then
    echo "compile-check: set REALTALK_GAME_DIR (or put it in server/local.conf)" >&2
    exit 2
fi
SCC="$GAME/engine/tools/scc.exe"
TMP=$(mktemp -d /tmp/st-compile-check.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# scc resolves the base cache as <scripts>/../cache/final.redscripts, so the
# temp tree must look like an r6/ directory.
# REAL COPIES, not symlinks: scc silently skips symlinked directories, and a
# tree of links compiles nothing and reports success (field-caught: the check
# said OK while the launch failed on three real errors).
mkdir -p "$TMP/r6/scripts" "$TMP/r6/cache"
cp -r "$GAME/r6/scripts"/. "$TMP/r6/scripts/"
cp "$GAME/r6/cache/final.redscripts" "$TMP/r6/cache/"
# THE WORKING COPY WINS. This used to compile only what was already deployed,
# so running the check before copying the new file over silently verified the
# OLD one - which is exactly how a broken build reached a real launch. The
# repo's scripts are overlaid last so the check always tests what was just
# written, whether or not it has been deployed yet.
REPO="$(cd "$(dirname "$0")" && pwd)"
[ -d "$REPO/r6/scripts" ] && cp -r "$REPO/r6/scripts"/. "$TMP/r6/scripts/"
cp "$GAME/red4ext/plugins/mod_settings"/*.reds "$TMP/r6/scripts/" 2>/dev/null
for plugin in ArchiveXL Codeware TweakXL; do
    cp "$GAME/red4ext/plugins/$plugin/Scripts"/*.reds "$TMP/r6/scripts/" 2>/dev/null
done

OUT="$TMP/out.redscripts"
LOG="$TMP/scc.log"
WAYLAND_DISPLAY= DISPLAY= timeout 300 wine "$SCC" -compile "$TMP/r6/scripts" "$OUT" >"$LOG" 2>&1

# scc copies the BASE cache to the output before compiling, so a non-empty
# output file proves nothing (field-caught: OK on scripts a real launch had
# just failed). Failure is detected the way the game reports it: error
# markers in the compiler output.
if [ -s "$OUT" ] && ! grep -qa "\[ERROR\|compilation has failed" "$LOG"; then
    echo "compile-check: OK"
    # Compiling clean says nothing about what the GAME will load. Say so out
    # loud rather than leaving a passing check to imply a deployed fix.
    # Only the files THIS repo owns. The game's script directory is full of
    # other people's mods, and comparing the whole tree reported drift on
    # every single run.
    drift=""
    while IFS= read -r f; do
        rel="${f#$REPO/r6/scripts/}"
        cmp -s "$f" "$GAME/r6/scripts/$rel" || drift="$drift $rel"
    done < <(find "$REPO/r6/scripts" -name '*.reds' 2>/dev/null)
    if [ -n "$drift" ]; then
        echo "compile-check: NOTE - not deployed yet:$drift"
    fi
    exit 0
fi
echo "compile-check: FAILED"
grep -a -A 4 "\[ERROR" "$LOG" | grep -iv "err:\|fixme:\|wayland\|WARNING\|listener" | head -40
exit 1
