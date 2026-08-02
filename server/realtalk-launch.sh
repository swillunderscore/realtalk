#!/bin/bash
# ============================================================================
#  RealTalk launcher wrapper - makes voice (and anything else) seamless.
# ============================================================================
#
#  Users already have to edit Steam Launch Options ONCE for -no-tls; this
#  rides that same edit, so the Play button does everything:
#
#      /path/to/realtalk-launch.sh %command% -no-tls
#
#  What it does: starts every sidecar listed in sidecars.conf that is not
#  already running, launches the game, waits for it to exit, then stops only
#  the sidecars IT started. Run your servers by hand and it leaves them
#  alone. No sidecars.conf, or empty = it just runs the game.
#
#  sidecars.conf: one command per line, # for comments. Relative paths
#  resolve against this directory. Default ships with the TTS server line;
#  add your model server too and the Play button becomes the whole ritual.
# ============================================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/sidecars.conf"
PIDFILE="$DIR/logs/sidecars.pids"
mkdir -p "$DIR/logs"

# Strays from a previous session. If the wrapper dies before its cleanup
# (game crash, Steam re-exec, power loss), its sidecars are orphaned - and
# the "already running - not touching it" check below then ADOPTS the
# orphan forever, serving stale code and holding VRAM across sessions
# (field-caught twice: a voice server, then a 7B model server pinned in
# VRAM long after the game closed). Every pid in this file is one WE
# started, so killing the survivors touches nothing hand-started.
if [ -f "$PIDFILE" ]; then
    STRAYS=0
    while IFS= read -r sp; do
        [ -n "$sp" ] && kill -TERM -"$sp" 2>/dev/null && STRAYS=1
    done < "$PIDFILE"
    : > "$PIDFILE"
    [ "$STRAYS" = "1" ] && { echo "[realtalk] cleaned up sidecars from a previous session"; sleep 1; }
fi
# First run: the shipped example becomes the live config (which is local to
# your machine and never committed - it holds your own paths).
if [ ! -f "$CONF" ] && [ -f "$CONF.example" ]; then
    cp "$CONF.example" "$CONF"
fi
PIDS=()

if [ -f "$CONF" ]; then
    while IFS= read -r line; do
        case "$line" in ""|\#*) continue;; esac
        # resolve relative commands against this dir
        cmd="$line"
        case "$cmd" in /*) : ;; *) cmd="$DIR/$cmd" ;; esac
        base="$(basename "${cmd%% *}")"
        # already running? leave it alone (also covers a hand-started one)
        if pgrep -f "$base" >/dev/null 2>&1; then
            echo "[realtalk] $base already running - not touching it"
            continue
        fi
        echo "[realtalk] starting $base"
        mkdir -p "$DIR/logs"
        setsid $cmd > "$DIR/logs/${base%.*}.log" 2>&1 &
        PIDS+=($!)
        echo "$!" >> "$PIDFILE"
    done < "$CONF"
fi

# the game, in the foreground - everything after our own path is the game's
# own command line, -no-tls included
"$@"
rc=$?

for p in "${PIDS[@]}"; do
    # negative pid = the whole process group we created with setsid
    kill -TERM -"$p" 2>/dev/null
done
: > "$PIDFILE"
[ "${#PIDS[@]}" -gt 0 ] && echo "[realtalk] stopped ${#PIDS[@]} sidecar(s)"
exit $rc
