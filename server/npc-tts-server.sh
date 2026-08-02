#!/bin/bash
# RealTalk TTS server launcher. Run this, then launch the game.
#
# First run: creates a venv and installs coqui-tts (the maintained fork of
# Coqui TTS; if pip can't find it, `pip install TTS` is the older name), then
# the first /speak request downloads XTTS-v2 (~2 GB) from Hugging Face. That
# download is the only network access this will ever do.
#
# CPU on purpose: your GPU is already running the game (and probably a local
# model). A spoken line takes a few seconds on CPU; the text has already
# appeared by then, and the voice follows it.
#
# PATHS ARE DERIVED, NOT WRITTEN DOWN. Installed, this script lives in
# <game>/tools/RealTalk/, so the game is two levels up - which is how the
# release works with zero configuration. That derivation is also VERIFIED
# rather than assumed: it broke a dev checkout, where ../.. is the source
# repo and not a game at all (field-caught - TTS died with "slot dir
# missing"). If it does not look like a Cyberpunk install, fall back to
# local.conf / REALTALK_GAME_DIR, and say so clearly instead of failing
# on a path nobody wrote.

DIR="$(cd "$(dirname "$0")" && pwd)"

# Machine-local overrides, never committed: REALTALK_GAME_DIR,
# REALTALK_WOLVENKIT, REALTALK_VGMSTREAM (see local.conf.example).
if [ -f "$DIR/local.conf" ]; then
    . "$DIR/local.conf"
fi

looks_like_game() { [ -d "$1/r6/audioware/RealTalk/slots" ]; }

GAME_DIR="${REALTALK_GAME_DIR:-}"
if [ -z "$GAME_DIR" ]; then
    CANDIDATE="$(cd "$DIR/../.." 2>/dev/null && pwd)"
    if [ -n "$CANDIDATE" ] && looks_like_game "$CANDIDATE"; then
        GAME_DIR="$CANDIDATE"
    fi
fi
GAME_SLOTS="$GAME_DIR/r6/audioware/RealTalk/slots"
VENV="$DIR/.venv"

export COQUI_TOS_AGREED=1   # XTTS asks once; non-interactive servers must pre-agree

if [ -z "$GAME_DIR" ] || [ ! -d "$GAME_SLOTS" ]; then
    echo "[ERROR] Could not find your Cyberpunk 2077 install."
    echo "        Expected the mod's audio slots at:"
    echo "          <game>/r6/audioware/RealTalk/slots"
    echo "        Either keep this script in <game>/tools/RealTalk/ (the"
    echo "        release layout), or set the path yourself - copy"
    echo "        local.conf.example to local.conf and edit it."
    exit 1
fi

if [ ! -d "$VENV" ]; then
    echo "[INFO] First run - creating venv ..."
    python3 -m venv "$VENV" || exit 1
    "$VENV/bin/pip" install --upgrade pip >/dev/null
fi

# Verified on EVERY start, not just first run: an incomplete venv used to
# leave a server that answered /health and then failed every actual request.
#
# torch/torchaudio are installed EXPLICITLY because coqui-tts does not
# declare them - it leaves the choice of CPU/CUDA/ROCm build to the user, so
# `pip install coqui-tts` alone produces a package that cannot run. CPU
# wheels on purpose: the GPU is busy with the game and the LLM.
if ! "$VENV/bin/python" -c "import torch, torchaudio, torchcodec" >/dev/null 2>&1; then
    echo "[INFO] Installing PyTorch CPU stack - a few hundred MB, one time ..."
    # ALL THREE from the CPU index. The default PyPI torchcodec is the CUDA
    # build and dies loading libnvrtc on machines without NVIDIA - and it
    # only gets exercised when decoding a reference clip, so it passes every
    # smoke test and fails on the first real cloned voice. CPU wheels work
    # on any machine, which is the point.
    "$VENV/bin/pip" install torch torchaudio torchcodec --index-url https://download.pytorch.org/whl/cpu || {
        echo "[ERROR] PyTorch install failed - see the output above"; exit 1; }
fi
if ! "$VENV/bin/python" -c "import TTS" >/dev/null 2>&1; then
    echo "[INFO] Installing coqui-tts ..."
    # transformers pinned below 5: 5.x removed isin_mps_friendly, which
    # coqui-tts still calls.
    "$VENV/bin/pip" install coqui-tts "transformers<5" || exit 1
fi

# Voice FORGING needs two external tools (WolvenKit CLI to read your
# archives, vgmstream to decode .wem). The Windows launcher downloads them;
# on Linux, point at your own copies with REALTALK_WOLVENKIT /
# REALTALK_VGMSTREAM, drop them beside this script, or leave them out -
# without them the server still runs and everyone gets a built-in voice
# instead of their own cloned one.
WOLVENKIT="${REALTALK_WOLVENKIT:-}"
[ -z "$WOLVENKIT" ] && [ -x "$DIR/wolvenkit/WolvenKit.CLI" ] && WOLVENKIT="$DIR/wolvenkit/WolvenKit.CLI"
[ -z "$WOLVENKIT" ] && WOLVENKIT="$(command -v WolvenKit.CLI 2>/dev/null || true)"
VGMSTREAM="${REALTALK_VGMSTREAM:-}"
[ -z "$VGMSTREAM" ] && [ -x "$DIR/vgmstream/vgmstream-cli" ] && VGMSTREAM="$DIR/vgmstream/vgmstream-cli"
[ -z "$VGMSTREAM" ] && VGMSTREAM="$(command -v vgmstream-cli 2>/dev/null || true)"
if [ -z "$WOLVENKIT" ] || [ -z "$VGMSTREAM" ]; then
    echo "[INFO] WolvenKit CLI / vgmstream not found - voice cloning from your"
    echo "       archives is off; NPCs will use built-in voices. See the README."
fi

# A voice server from a previous game session can outlive the game and keep
# the port - every newer launch then dies with "address already in use" and
# the survivor serves STALE CODE with its output going to a rotated-away log
# (field-caught: a server from 16:46 was still answering an evening session).
# One server, always the newest code:
pkill -f "realtalk-tts.py" 2>/dev/null && sleep 1

# XTTS-v2 model weights are published by Coqui under the Coqui Public Model
# License (non-commercial). The library downloads them from Hugging Face on
# first run and asks for interactive license agreement, which a background
# server can never answer - this accepts it, and this notice is the disclosure.
echo "[tts] first run downloads the XTTS-v2 voice model (Coqui Public Model License, non-commercial use)"
export COQUI_TOS_AGREED=1

exec "$VENV/bin/python" "$DIR/realtalk-tts.py" \
    --slots "$GAME_SLOTS" \
    --voices "$DIR/voices" \
    --port 8082 \
    --device cpu \
    --game-dir "$GAME_DIR" \
    --wolvenkit "$WOLVENKIT" \
    --vgmstream "$VGMSTREAM"
