#!/usr/bin/env python3
"""Forge an XTTS reference clip for a character from the player's OWN game
archives - the actual actor's lines, extracted locally, never distributed.

HOW, all verified on real data:
  - Voice-over filenames are self-describing: <speaker>_<quest>_<gender>_<hash>.wem
    (e.g. mama_welles_sq018_f_19db....wem - 123 of her lines in one quest).
    The speaker slug is the display name lowercased with underscores, with a
    small alias table for the exceptions (victor_vector vs "Viktor Vektor").
  - WolvenKit CLI extracts by that filename pattern from lang_en_voice.archive.
  - The wems are Wwise audio ffmpeg cannot decode; vgmstream-cli can
    (48 kHz mono wav out, measured).
  - A handful of 2-9 s lines are concatenated to an ~18 s reference clip,
    which is exactly what XTTS wants for cloning.

This runs ON DEMAND from the TTS server: the first time the player talks to
a character with no clip, the clip is forged from their archives. Zero setup,
and it works for every named, voiced NPC in the game.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import wave

# display-name slug -> VO filename prefix, where they differ
ALIASES = {
    "viktor_vektor": "victor_vector",
}

MIN_CLIP = 2.0     # seconds - shorter lines are mostly grunts
MAX_CLIP = 10.0    # longer ones tend to include pauses/scene noise
TARGET_TOTAL = 60.0   # matches the conditioning window the server now asks
                      # for (max_ref_length=60); the model attends up to 30s
                      # of gpt conditioning chosen from these
MAX_DECODES = 80
MAX_PARTS = 8

# Bumped ONLY when the forge itself improves; clips stamped with an older
# version re-forge once. (The previous staleness check compared clip length
# to a target the forge could not always reach - every chat open re-forged,
# recomputed conditioning, and showed "learning their voice" forever.)
# 4: rebuild every reference clip once. Voices forged before the gender filter
# could mix a character's male and female lines into one chimera - V, whose
# 21k lines contain both, most of all.
FORGE_VERSION = 4


import json as _json
import re as _re
from collections import Counter as _Counter

_QUESTISH = _re.compile(r"^(q\d+|sq\d+|mq\d+|sts\d*|ep\d+|prologue|default|finalboards|holo.*|\d+)$")


# Bumped when the roster covers more than it used to, so old caches rebuild.
ROSTER_VERSION = 2


def voice_archives(game_dir: str) -> list:
    """EVERY voice archive this install has. Phantom Liberty ships its own
    1.6 GB of dialogue in archive/pc/ep1, and only the base one was ever
    opened - so Songbird, Reed, Myers and Alex had no lines, no gender and no
    quests, and nothing said why: they are simply not in the file we looked in.
    """
    return [p for p in (
        os.path.join(game_dir, "archive", "pc", "content", "lang_en_voice.archive"),
        os.path.join(game_dir, "archive", "pc", "ep1", "lang_en_voice.archive"),
    ) if os.path.isfile(p)]


def text_archives(game_dir: str) -> list:
    """Subtitles, same story - the expansion keeps its own."""
    return [p for p in (
        os.path.join(game_dir, "archive", "pc", "content", "lang_en_text.archive"),
        os.path.join(game_dir, "archive", "pc", "ep1", "lang_en_text.archive"),
    ) if os.path.isfile(p)]


def speaker_roster(game_dir: str, wolvenkit: str, cache_path: str, log=print):
    """{speaker_slug: line_count} for the whole voice archive. Built once
    from the archive file list (no extraction), cached to disk."""
    if os.path.isfile(cache_path):
        try:
            cached = _json.load(open(cache_path))
            # A roster built before the expansion was included is missing
            # every character in it, and would never rebuild on its own.
            if cached.get("__v") == ROSTER_VERSION:
                return cached
        except Exception:
            pass
    env = dict(os.environ, DOTNET_ROLL_FORWARD="LatestMajor")
    out = ""
    for arch in voice_archives(game_dir):
        out += subprocess.run([wolvenkit, "archiveinfo", arch, "-l"],
                              capture_output=True, text=True, env=env,
                              timeout=300).stdout
    speakers = _Counter()
    for name in _re.findall(r"([a-z0-9_]+)\.wem", out):
        parts = name.rsplit("_", 2)
        if len(parts) != 3 or parts[1] not in ("f", "m"):
            continue
        toks = parts[0].split("_")
        while len(toks) > 1 and _QUESTISH.match(toks[-1]):
            toks.pop()
        speakers["_".join(toks)] += 1
    roster = dict(speakers)
    roster["__v"] = ROSTER_VERSION
    try:
        _json.dump(roster, open(cache_path, "w"))
    except Exception:
        pass
    log(f"[forge] speaker roster built: {len(roster)} speakers")
    return roster


def resolve_speaker(display_name: str, roster: dict) -> str:
    """The name the ARCHIVE uses for this character.

    Display names and archive speakers are not the same thing: the game calls
    her "Panam Palmer", her 2442 voice lines are filed under "panam", and
    "panam_palmer" matches nothing at all. The voice ladder always knew this
    and fell back to name tokens - but the gender lookup and the dialogue
    harvest did not, so for every two-word character they searched a name that
    does not exist and silently found nothing. One resolver now, used by all of
    them.
    """
    slug = slugify(display_name)
    if not slug:
        return ""
    if roster.get(slug, 0) > 0:
        return slug
    best, best_n = "", 0
    for tok in slug.split("_"):
        if len(tok) >= 4 and roster.get(tok, 0) > best_n:
            best, best_n = tok, roster.get(tok, 0)
    return best


def speaker_gender(display_name: str, game_dir: str, wolvenkit: str,
                   cache_path: str, log=print) -> str:
    """Which rig is this character? Their voice filenames say so - every line
    is tagged f or m - and some characters (Panam) carry no gender at all in
    their game record, which was making the mod skip their gestures entirely.
    Cached next to the roster."""
    import json as _j
    slug = slugify(display_name)
    if not slug:
        return ""
    cache = {}
    if os.path.isfile(cache_path):
        try:
            cache = _j.load(open(cache_path))
        except Exception:
            cache = {}
    # Same stamp as the roster: an answer worked out from one archive when
    # there are two is not an answer worth keeping. Characters who came back
    # blank stayed blank forever, which is how a gestureless NPC becomes
    # permanent (the log's "gender=?" on chat open).
    if cache.get("__v") != ROSTER_VERSION:
        cache = {"__v": ROSTER_VERSION}
    elif slug in cache:
        return cache[slug]
    archives = voice_archives(game_dir)
    if not (archives and os.path.isfile(wolvenkit)):
        return ""
    env = dict(os.environ, DOTNET_ROLL_FORWARD="LatestMajor")
    out = ""
    for arch in archives:
        out += subprocess.run([wolvenkit, "archiveinfo", arch, "-l"],
                              capture_output=True, text=True, env=env,
                              timeout=600).stdout
    # the archive's own name for them, not the display name
    roster = speaker_roster(game_dir, wolvenkit,
                            os.path.join(os.path.dirname(cache_path), "roster.json"),
                            log=log)
    real = resolve_speaker(display_name, roster) or slug
    f = m = 0
    for name in _re.findall(r"([a-z0-9_]+)\.wem", out):
        if not name.startswith(real + "_"):
            continue
        parts = name.rsplit("_", 2)
        if len(parts) == 3 and parts[1] in ("f", "m"):
            if parts[1] == "f":
                f += 1
            else:
                m += 1
    g = "" if (f + m) == 0 else ("f" if f >= m else "m")
    cache[slug] = g
    try:
        _j.dump(cache, open(cache_path, "w"))
    except Exception:
        pass
    if g:
        log(f"[forge] {display_name} reads as '{g}' from {f + m} voice lines")
    return g


def slugify(display_name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "_", (display_name or "").lower()).strip("_")
    return ALIASES.get(s, s)


def forge(display_name: str, out_wav: str, game_dir: str, wolvenkit: str,
          vgmstream: str, log=print, slug_override: str = "",
          gender: str = "") -> bool:
    # slug_override is for VOICE TAGS off the character record - already in
    # VO filename form (civ_..., gang_val_m_15_mex_30), no name transform.
    slug = slug_override.lower().strip() if slug_override else slugify(display_name)
    if not slug:
        return False
    archives = voice_archives(game_dir)
    if not (archives and os.path.isfile(wolvenkit) and os.path.isfile(vgmstream)):
        log(f"[forge] missing tool or archive (archives={len(archives)})")
        return False

    outdir = os.path.dirname(os.path.abspath(out_wav))
    os.makedirs(outdir, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="voforge_", dir=outdir)
    try:
        env = dict(os.environ, DOTNET_ROLL_FORWARD="LatestMajor")
        log(f"[forge] extracting '{slug}' lines from your archives ...")
        # Leading * is load-bearing: WolvenKit patterns match the FULL archive
        # path (base\localization\en-us\vo\...), so an unanchored name matches
        # nothing. '?' covers the path separator; anchoring on \vo\ keeps the
        # match on the filename, not some folder.
        for archive in archives:
            subprocess.run(
                [wolvenkit, "unbundle", archive, "-o", tmp,
                 "-w", f"*vo?{slug}_*"],
                capture_output=True, text=True, env=env, timeout=900)

        wems = [os.path.join(dp, f)
                for dp, _, fs in os.walk(tmp)
                for f in fs
                if f.endswith(".wem") and f.startswith(slug + "_")]
        # GENDER FILTER, and V is why it exists: male and female V share the
        # single speaker slug "v" (21k lines), so forging it unfiltered would
        # clone a chimera of both voices. Filenames carry the gender token -
        # <speaker>_<quest>_<f|m>_<hash>.wem - so the pool can be split.
        g = "f" if gender.lower().startswith("f") else (
            "m" if gender.lower().startswith("m") else "")
        if g:
            same = [w for w in wems
                    if os.path.basename(w).rsplit("_", 2)[-2:-1] == [g]]
            if len(same) >= 8:
                log(f"[forge] {len(same)} of {len(wems)} lines are '{g}' - "
                    f"using only those")
                wems = same
        if not wems:
            log(f"[forge] no voice lines named '{slug}_*' - not a voiced "
                f"named character (crowd NPCs land here)")
            return False
        log(f"[forge] {len(wems)} lines found")

        # Decode a wide pool, then CHOOSE: cleanest, driest clips win, not
        # the biggest files (biggest often means shouting over scene noise).
        # Score = speech level over noise floor, from 50 ms RMS windows.
        wems.sort(key=os.path.getsize, reverse=True)
        scored = []
        for w in wems[:MAX_DECODES]:
            dst = w + ".wav"
            r = subprocess.run([vgmstream, "-o", dst, w],
                               capture_output=True, timeout=60)
            if r.returncode != 0 or not os.path.isfile(dst):
                continue
            try:
                with wave.open(dst) as wf:
                    dur = wf.getnframes() / wf.getframerate()
                    rate = wf.getframerate()
                    import numpy as np
                    pcm = np.frombuffer(wf.readframes(wf.getnframes()),
                                        dtype="<i2").astype("f4")
            except Exception:
                continue
            if not (MIN_CLIP <= dur <= MAX_CLIP) or pcm.size < rate:
                continue
            win = max(1, rate // 20)
            n = pcm.size // win
            rms = ((pcm[:n * win].reshape(n, win) ** 2).mean(axis=1)) ** 0.5
            rms = rms[rms > 1.0]
            if rms.size < 10:
                continue
            noise = float(np.percentile(rms, 10)) + 1.0
            speech = float(np.percentile(rms, 90)) + 1.0
            scored.append((speech / noise, dur, dst))
        scored.sort(reverse=True)
        clips, total = [], 0.0
        for _, dur, dst in scored:
            clips.append(dst)
            total += dur
            if total >= TARGET_TOTAL or len(clips) >= MAX_PARTS:
                break
        if not clips:
            # Tiny speakers: if the 2-10s window rejected everything, take
            # whatever decodable speech exists. Two lines is still a voice.
            for w in wems[:MAX_DECODES]:
                dst = w + ".wav"
                if os.path.isfile(dst):
                    try:
                        with wave.open(dst) as wf:
                            d = wf.getnframes() / wf.getframerate()
                    except Exception:
                        continue
                    if 0.7 <= d <= 15.0:
                        clips.append(dst)
                        total += d
                    if len(clips) >= MAX_PARTS:
                        break
        if not clips:
            log("[forge] nothing usable after decode")
            return False

        # Pure-python concat: every clip is 48k mono s16 straight out of
        # vgmstream, so joining is just frames. This removes the server's
        # last external dependency (ffmpeg) - one less thing between a user
        # and "it just works from the launch options".
        try:
            with wave.open(out_wav, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(48000)
                for c in clips:
                    with wave.open(c) as r:
                        w.writeframes(r.readframes(r.getnframes()))
        except Exception as e:
            log(f"[forge] concat failed: {e}")
            return False

        # ALSO keep individual lines: XTTS conditions noticeably better from
        # several separate clips than one long concatenation, and the API
        # takes a list. The concat stays for compatibility and overrides.
        parts = out_wav + ".parts"
        os.makedirs(parts, exist_ok=True)
        for i, c in enumerate(clips[:MAX_PARTS]):
            shutil.copy(c, os.path.join(parts, f"{i}.wav"))
        with open(out_wav + ".ver", "w") as f:
            f.write(str(FORGE_VERSION))
        log(f"[forge] {os.path.basename(out_wav)}: {len(clips)} lines, "
            f"{total:.1f}s of their real voice")
        return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 6:
        print("usage: voice_forge.py <display name> <out.wav> <game_dir> "
              "<wolvenkit_cli> <vgmstream_cli>")
        sys.exit(1)
    ok = forge(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    sys.exit(0 if ok else 2)
