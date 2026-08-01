#!/bin/bash
# Build the Nexus release zip.
#
# Layout is GAME-ROOT RELATIVE, so a mod manager (or a manual drag) puts
# every piece where it belongs in one step:
#
#   r6/scripts/StreetTalk/      the mod
#   r6/audioware/StreetTalk/    voice slots (harmless without Audioware)
#   tools/StreetTalk/           the voice server + launchers (README path)
#
# Deliberately EXCLUDED: the python venv, forged voices and roster (game
# audio derived from the player's own archives - never redistributable),
# logs, __pycache__, and sidecars.conf (machine-local paths). The shipped
# sidecars.conf.example seeds itself on first launch.
set -eu
cd "$(dirname "$0")"
VERSION="${1:-$(date +%Y.%m.%d)}"
OUT="dist/StreetTalk-$VERSION.zip"
STAGE="dist/stage"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/r6/scripts" "$STAGE/r6/audioware" "$STAGE/tools/StreetTalk" dist

cp -r r6/scripts/StreetTalk "$STAGE/r6/scripts/"
cp -r r6/audioware/StreetTalk "$STAGE/r6/audioware/"
cp server/streettalk-tts.py server/voice_forge.py \
   server/npc-tts-server.sh server/streettalk-launch.sh \
   server/sidecars.conf.example "$STAGE/tools/StreetTalk/"
# FLAT, not in a windows/ subfolder: the .bat resolves the game dir as
# ..\.. from its own location and calls streettalk-tts.py beside itself, and
# the README's launch line points at tools\StreetTalk\streettalk-launch.bat.
# Both launchers coexist harmlessly; each OS ignores the other's.
cp server/windows/streettalk-launch.bat server/windows/bootstrap.ps1 "$STAGE/tools/StreetTalk/"
cp README.md "$STAGE/"

# Nothing derived from the game, and nothing machine-local, may ship.
# (The four r6/audioware slot wavs are OURS: 0.2s of generated silence the
# manifest needs as placeholders - verified all-zero samples - so the audio
# check is scoped to tools/, where forged voices would be.)
BAD=$(find "$STAGE/tools" \( -name "*.wav" -o -name "*.lat" \) -print
      find "$STAGE" \( -name "roster.json" -o -name "sidecars.conf" \
        -o -name "__pycache__" -o -name "*.log" \) -print)
if [ -n "$BAD" ]; then
    echo "REFUSING: game-derived or machine-local files in the package"
    echo "$BAD"
    exit 1
fi

# No developer machine paths may reach a stranger's PC (field-caught: the
# linux launcher shipped three hardcoded absolute paths).
# Any absolute path from the machine that built this - a home directory, a
# mount point, a Windows user folder - is both a bug and a privacy leak.
if grep -rIlE -e "/home/[a-zA-Z0-9._-]+" -e "/Users/[a-zA-Z0-9._-]+" -e "[A-Za-z]:\\\\Users\\\\" -e "/mnt/[a-zA-Z0-9._-]+" "$STAGE" | grep -q .; then
    echo "REFUSING: developer paths found in the package"
    grep -rInE -e "/home/[a-zA-Z0-9._-]+" -e "/Users/[a-zA-Z0-9._-]+" -e "[A-Za-z]:\\\\Users\\\\" -e "/mnt/[a-zA-Z0-9._-]+" "$STAGE" | head
    exit 1
fi

(cd "$STAGE" && zip -qr "../../$OUT" .)
rm -rf "$STAGE"
echo "built $OUT"
unzip -l "$OUT" | tail -3
