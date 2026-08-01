#!/usr/bin/env python3
"""StreetTalk TTS server.

Synthesises NPC replies in cloned voices and writes them into the Audioware
slot files the mod plays. 100% local: XTTS-v2 runs on this machine; nothing
leaves it. The one network access EVER is the first run, when the model
weights (~2 GB) download from Hugging Face.

    POST /speak   { "text": "...", "voice": "Mama Welles", "slot": 0 }
        -> synthesises with voices/<voice>.wav as the reference clip
           (voices/default.wav if that speaker has no clip yet),
           writes slots/slot_<N>.wav ATOMICALLY (temp file + rename, so the
           game can never read a half-written wav), then responds. The mod
           plays the slot only after this response arrives.
    GET /health   -> {"status":"ok"}

Voices are just reference clips: put 10-20 seconds of clean speech at
voices/<Display Name>.wav and that's the voice. Record it straight from the
game (the NPC talking, no music/gunfire) - that IS the voice-cloning data.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import threading
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import voice_forge

ARGS = None

# Conversations are private. Nothing the player types and nothing an NPC says
# is ever written to the log unless this is switched on deliberately
# (STREETTALK_LOG_CONTENT=1) - the structural lines alone diagnosed every bug
# in this file's history, and the stage-direction words are only needed when
# actively extending the animation thesaurus.
# Set by STREETTALK_LOG_CONTENT=1, and ALSO switched on per request by the
# game's own Debug Log setting (every request carries "log"). One toggle in
# Mod Settings therefore controls both logs: off means neither writes
# anything, on means both write everything - which is what a debug log is
# for.
# ---- voice conditioning, the one place it is decided ----
# 30 seconds is the model card's own value and is what these voices were
# built and judged on. It was briefly lowered to 12 to save CPU during a
# latency pass, and the result was audible and bad: V drifted into a British
# accent and cloned voices went thin and speaker-phone-ish. Speaker similarity
# is the whole point of this feature, so it goes back up - if lines ever feel
# too slow, the answer is shorter replies, not a worse voice.
COND_SECONDS = [30]   # live value, set from the game's Voice Detail setting
COND_MAX_REF = 60
COND_VERSION = 4      # bump to invalidate every cached latent on disk

LOG_CONTENT = os.environ.get("STREETTALK_LOG_CONTENT", "") == "1"
# Set per request from the game's "Character Lookup" setting. Off means the
# server never opens a socket to anywhere but this machine.
WIKI_OK = [False]
# Did the last resolve actually build a voice, or just load a cached one?
FORGED_NOW = [False]
MODEL = None
MODEL_LOCK = threading.Lock()   # XTTS is not thread-safe
FORGE_FAILED = set()   # characters we already tried and could not forge
FORGE_LOCK = threading.Lock()   # prep and speak may race on the same voice

# ---- sentence-chunked synthesis ----
# The whole point: the NPC starts talking after the FIRST sentence is ready
# instead of after the whole reply. Chunk 1 returns immediately; the rest
# synthesize on a background thread and the game fetches them in order.
SESSIONS = {}
SESSIONS_LOCK = threading.Lock()
MAX_SESSIONS = 8


# Bumped when a harvest bug means every cached file is worth redoing.
EXAMPLES_CACHE_VERSION = 3

# Quest ids as the archives spell them: q005, q103, sq027, mq012, ep1q000.
_QUEST_ID = re.compile(r"^(?:ep\d+)?(?:q|sq|mq)\d{3}[a-z]?$")

def split_sentences(text: str):
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+", text.strip()) if p.strip()]
    # merge fragments so no chunk is awkwardly tiny
    chunks = []
    for p in parts:
        if chunks and (len(p) < 20 or len(chunks[-1]) < 20):
            chunks[-1] += " " + p
        else:
            chunks.append(p)
    return chunks[:6] if chunks else [text.strip()]


def wav_ms(path: str) -> int:
    with wave.open(path) as w:
        return int(w.getnframes() * 1000 / w.getframerate())


# Conditioning latents per reference clip, computed ONCE. The high-level
# tts_to_file re-derives them from the 20-30s reference on EVERY call, which
# is a large slice of per-line latency for pure waste.
LAT_CACHE = {}

# Measured synthesis characteristics, exponentially averaged. These drive
# the gapless gate: playback starts only when the audio already banked will
# outlast the projected time to synthesize the rest.
SPC = [0.055]    # seconds of speech per character of text
SPEED = [1.3]    # wall seconds per second of speech


def get_latents(syn, ref):
    """Conditioning for a reference voice: RAM cache, then disk cache (so a
    server restart does not recompute), then compute.

    THE QUALITY SETTINGS, in one place, deliberately chosen:
      reference clip   up to 8 of the character's cleanest lines, ~60s total,
                       scored by speech-to-noise and kept as separate parts
                       (several distinct clips condition better than one long
                       concatenation)
      gpt_cond_len 12  the conditioning window, in seconds. The model's own
                       default is 6, which ignored most of the reference we
                       built. 30 is the model card's showcase value and is
                       audibly good, but conditioning tokens ride along with
                       EVERY generated word, so 30 made each spoken line
                       markedly slower on CPU - measured, not assumed. 12 is
                       the deliberate point: twice the default's speaker
                       information, without the per-line tax.
      max_ref_length 30, sound_norm_refs True (levels clips against each other)

    Raising gpt_cond_len is a one-line change if slower, slightly closer
    voices are ever the better trade."""
    if ref in LAT_CACHE:
        return LAT_CACHE[ref]
    import torch
    # The cache filename carries the settings version: change the
    # conditioning and every stale latent is ignored automatically, instead of
    # quietly serving voices built to the old spec.
    # The window length is part of the key, so switching between settings
    # reuses each one's cache instead of recomputing forever.
    lat_path = f"{ref}.lat{COND_VERSION}_{COND_SECONDS[0]}"
    if os.path.isfile(lat_path) and os.path.getmtime(lat_path) >= os.path.getmtime(ref):
        try:
            LAT_CACHE[ref] = torch.load(lat_path, map_location="cpu", weights_only=False)
            return LAT_CACHE[ref]
        except Exception:
            pass
    import glob as _glob
    refs = sorted(_glob.glob(ref + ".parts/*.wav")) or [ref]
    lat = syn.get_conditioning_latents(
        audio_path=refs, gpt_cond_len=COND_SECONDS[0], gpt_cond_chunk_len=6,
        max_ref_length=COND_MAX_REF, sound_norm_refs=True)
    try:
        torch.save(lat, lat_path)
    except Exception:
        pass
    LAT_CACHE[ref] = lat
    print(f"[tts] conditioning cached: {os.path.basename(ref)}", flush=True)
    return lat

def trim_silence(pcm, rate=24000, thresh=260, pad_ms=60):
    """Cut leading/trailing silence from int16 pcm. XTTS pads its output at
    both ends; butted chunks then have a baked-in gap no scheduling removes.
    thresh ~ -42 dBFS. (This was accidentally deleted alongside the tuned-
    model block - every line since fell back to the slow no-cache path.)"""
    import numpy as np
    loud = np.flatnonzero(np.abs(pcm.astype("i4")) > thresh)
    if loud.size == 0:
        return pcm
    pad = int(rate * pad_ms / 1000)
    a = max(0, int(loud[0]) - pad)
    b = min(pcm.size, int(loud[-1]) + pad)
    return pcm[a:b]


def synth_to_tmp(text: str, voice_kw: dict, gain: float = 1.0) -> str:
    import time as _time
    t0 = _time.monotonic()
    fd, tmp = tempfile.mkstemp(suffix=".wav", dir=ARGS.slots)
    os.close(fd)
    ref = voice_kw.get("speaker_wav")
    with MODEL_LOCK:
        m = get_model()
        if ref:
            try:
                syn = m.synthesizer.tts_model
                # ONE conditioning path, not two. This used to compute its
                # own latents with different settings (30s/60s) from the
                # warm-up path's (12s/30s), so a voice's quality depended on
                # which request happened to reach it first - and this copy
                # never wrote the disk cache, so it recomputed every restart.
                # get_latents is now the only way latents are ever made.
                gpt, emb = get_latents(syn, ref)
                out = syn.inference(text, "en", gpt, emb)
                import numpy as np
                # GAIN. V's lines play NON-POSITIONALLY (they come from the
                # player, who is the listener), so they get none of the
                # distance attenuation an NPC's emitter gets - which made V
                # audibly louder than the game's own V lines, clear as day in
                # a waveform. Scaling here rather than in the game keeps it
                # one multiply on audio we are already writing.
                wav = np.clip(out["wav"], -1.0, 1.0)
                if gain != 1.0:
                    wav = np.clip(wav * gain, -1.0, 1.0)
                pcm = (wav * 32767).astype("<i2")
                pcm = trim_silence(pcm)
                with wave.open(tmp, "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(24000)   # XTTS output rate
                    w.writeframes(pcm.tobytes())
                _learn(text, tmp, t0)
                return tmp
            except Exception as e:
                print(f"[tts] fast path failed ({e}) - falling back", flush=True)
        m.tts_to_file(text=text, language="en", file_path=tmp, **voice_kw)
    _learn(text, tmp, t0)
    return tmp


def _learn(text, tmp, t0):
    import time as _time
    try:
        dur = wav_ms(tmp) / 1000.0
        wall = _time.monotonic() - t0
        if dur > 0.3 and len(text) > 5:
            SPC[0] = 0.8 * SPC[0] + 0.2 * (dur / len(text))
            SPEED[0] = 0.8 * SPEED[0] + 0.2 * (wall / dur)
    except Exception:
        pass


def chunk_worker(sid: str):
    s = SESSIONS.get(sid)
    if not s:
        return
    for i in range(1, len(s["chunks"])):
        try:
            s["wavs"][i] = synth_to_tmp(s["chunks"][i], s["kw"],
                                        s.get("gain", 1.0))
        except Exception as e:
            print(f"[tts] chunk {i} failed: {e}", flush=True)
        s["events"][i].set()


EXAMPLES_LOCK = threading.Lock()
EXAMPLES_DONE = set()


# Words a sentence can start with without naming anybody. Anything else
# capitalised is treated as a person or a place.
_COMMON_STARTS = set("""
a about after all alright am an and another any anybody anyone anything are
as ask at back be because been before better big both bring but by call came
can cant care careful check come could couldnt course did didnt do does dont
down easy either enough even ever every everybody everyone eyes fine first for
forget from fuck get give go going gonna good got gotta guess had hands has
have he hell hello her here hey him his hold how i if in into is it its just
keep kind know last let lets like listen little long look made make man many
maybe me mind more move much my never new next nice no nobody not nothing now
of off oh ok okay on once one only or other our out over please pretty put
quiet really right said same say see she should shit show so some someone
something sometimes soon sorry stay still stop such sure take tell than that
thats the their them then there these they thing think this those thought
time to told too try turn two up us wait want was watch way we well were what
when where which while who why will with without wont would yeah yes yet you
your youre
""".split())


def _names_someone(line: str, speaker_slug: str) -> bool:
    """Does this line name a person or a place?

    Panam's biggest quest is the Hellman job, so the harvest handed her eight
    lines and two of them said "Hellman" - and she brought him up with a
    player who had never mentioned him and was not on that mission (field
    report). Examples are supposed to teach how someone TALKS. A name is a
    subject, and a small model repeats subjects.
    """
    words = re.findall(r"[A-Za-z][A-Za-z'\-]*", line)
    own = speaker_slug.split("_")
    for raw in words:
        # "Let's" and "lets" are the same word for this purpose.
        w = re.sub(r"[^A-Za-z]", "", raw)
        if len(w) == 0 or not w[0].isupper() or len(w) < 4:
            continue          # lower case, or short enough to be I / OK / TV
        if w.lower() in _COMMON_STARTS or w.lower() in own:
            continue          # an ordinary word, or their own name
        return True
    return False


def harvest_examples(slug: str, wems_dir_hint: str = "", alias: str = ""):
    """Write ~8 of this character's REAL spoken lines to the game's storage
    dir, where the mod reads them as few-shot examples. Their own dialogue
    is the strongest possible defence against generic-assistant voice
    ('from classic cocktails to custom concoctions' - field report).

    Voice filenames carry the same 64-bit id the subtitle files use, so
    audio and transcript join mechanically. Runs in the background after a
    forge; examples land for the NEXT conversation, and are cached forever.
    """
    import glob as _glob
    import json as _json
    import subprocess as _sp
    import tempfile as _tf
    import shutil as _sh
    out_dir = os.path.join(ARGS.game_dir, "r6", "storages", "StreetTalk")
    # alias: write under a different name than the speaker - a crowd NPC
    # shows as "NC Resident" but speaks with e.g. civ_low_f_16's voice, and
    # the game looks the file up by DISPLAY name. The lines inside are still
    # the real speaker's real dialogue.
    out_path = os.path.join(out_dir, f"examples_{alias or slug}.json")
    if not os.path.isdir(out_dir):
        return
    # A CACHE THAT CAN BE WRONG NEEDS A WAY TO BE RIGHT LATER. "The file
    # exists" used to be the whole test, so the caches written before the
    # quest-id filter - the ones that opened "downtown" and "finalboards"
    # looking for Panam's dialogue and found none - would have stayed empty
    # forever, on every install that had already met her. A version stamp
    # re-harvests them once, by itself.
    if os.path.isfile(out_path):
        try:
            with open(out_path) as f:
                if _json.load(f).get("v") == EXAMPLES_CACHE_VERSION:
                    return
        except Exception:
            pass
        print(f"[tts] {alias or slug}: cache predates the quest-id filter, "
              f"harvesting again", flush=True)
    env = dict(os.environ, DOTNET_ROLL_FORWARD="LatestMajor")
    # Base game AND Phantom Liberty - see voice_forge.voice_archives.
    voice_archs = voice_forge.voice_archives(ARGS.game_dir)
    text_archs = voice_forge.text_archives(ARGS.game_dir)
    tmp = _tf.mkdtemp(prefix="stex_")
    try:
        listing = ""
        for a in voice_archs:
            listing += _sp.run([ARGS.wolvenkit, "archiveinfo", a, "-l"],
                               capture_output=True, text=True, env=env,
                               timeout=300).stdout
        names = [n for n in re.findall(r"([a-z0-9_]+)\.wem", listing)
                 if n.startswith(slug + "_")]
        if not names:
            return
        # (quest ids are worth caching even when no subtitle text pairs up)
        hashes = {}
        quests = {}    # quest id -> how many lines they speak in it
        ambient = {}   # open-world bucket -> same
        fcount = 0
        mcount = 0
        for n in names:
            parts = n.rsplit("_", 2)
            if len(parts) != 3 or parts[1] not in ("f", "m"):
                continue
            if parts[1] == "f":
                fcount += 1
            else:
                mcount += 1
            hashes[parts[2]] = None
            # EVERY token between the name and the gender tag, keeping the
            # ones shaped like quest ids. Two bugs lived in the old one-token
            # version, and Judy had both: it read the LAST token, so
            # judy_mq055_01_megabuilding_f_*.wem filed her under "megabuilding"
            # rather than mq055, and nothing filtered the result, so districts
            # and "default" sat in her quest list as though they were quests.
            for tok in (parts[0][len(slug) + 1:].split("_")
                        if len(parts[0]) > len(slug) else []):
                if _QUEST_ID.match(tok):
                    quests[tok] = quests.get(tok, 0) + 1
                elif len(tok) > 2:
                    # NOT junk after all - just not a quest. These name the
                    # open-world buckets this character speaks in (northside,
                    # downtown, megabuilding), and that is where their
                    # PLOTLESS dialogue lives.
                    ambient[tok] = ambient.get(tok, 0) + 1
        # OPEN-WORLD FIRST, QUESTS ONLY IF THERE IS NOTHING ELSE.
        #
        # Examples are supposed to teach VOICE. Quest dialogue teaches the
        # plot with it: Panam's biggest quests are the Hellman job, so eight
        # of her lines came back naming Hellman, and she brought him up with a
        # player who was not on that mission and had never mentioned him
        # (field report). The game keeps 2147 open-world subtitle files
        # against 785 quest ones, and the open-world ones are the same person
        # talking about nothing in particular - which is exactly what is
        # wanted here.
        # THE VOICESET FIRST. Every named character has one - the lines they
        # say when no scene is running - and it is the only bucket with no
        # plot in it at all (subtitles/quest/vset/vset_panam.json, 96 lines).
        # Then their biggest quests, for conversational range: a voiceset is
        # mostly combat barks, and eight of those would make anyone sound like
        # they are mid-firefight.
        patterns = [f"*subtitles?quest?vset?vset_{slug}*"]
        patterns += [f"*subtitles?quest?{q}?*"
                     for q in sorted(quests, key=lambda k: -quests[k])[:2]]
        for pat in patterns:
            for a in text_archs:
                _sp.run([ARGS.wolvenkit, "unbundle", a, "-o", tmp,
                         "-w", pat],
                        capture_output=True, text=True, env=env, timeout=600)
        subs = [f for f in _glob.glob(os.path.join(tmp, "**", "*.json"), recursive=True)
                if not f.endswith(".json.json")]
        for f in subs[:40]:
            _sp.run([ARGS.wolvenkit, "convert", "serialize", f],
                    capture_output=True, text=True, env=env, timeout=120)
        lines = []

        def walk(o):
            if isinstance(o, dict):
                sid_ = o.get("stringId")
                if sid_ is not None:
                    sid_ = sid_.get("$value", sid_) if isinstance(sid_, dict) else sid_
                    fv = o.get("femaleVariant") or o.get("maleVariant") or ""
                    if isinstance(fv, dict):
                        fv = fv.get("$value", "")
                    try:
                        h = format(int(sid_), "x")
                    except (ValueError, TypeError):
                        return
                    if h in hashes and fv:
                        t = re.sub(r"<[^>]+>", "", str(fv)).strip()
                        if 12 <= len(t) <= 110:
                            lines.append(t)
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        for f in _glob.glob(os.path.join(tmp, "**", "*.json.json"), recursive=True):
            try:
                walk(_json.load(open(f)))
            except Exception:
                pass
        seen, picked = set(), []
        for t in lines:
            k = t.lower()
            if k in seen or _names_someone(t, slug):
                continue
            seen.add(k)
            picked.append(t)
            if len(picked) >= 8:
                break
        if picked or quests:
            # THE QUESTS THIS CHARACTER IS IN, straight from their voice-line
            # filenames (<speaker>_<quest>_<gender>_<hash>.wem). Takemura's
            # files name q005, q101, q104, q112, q113, q115, q201 - his actual
            # storyline - so nobody has to hand-maintain a list of who matters
            # to which quest. It comes from the player's own install and covers
            # every voiced character, including ones nobody remembers the name
            # of.
            # GENDER FROM THEIR OWN VOICE FILES. Panam's character record has
            # no gender entries and no template path, so the game could not
            # tell us her rig and gestures were skipped entirely - but every
            # one of her voice lines is tagged f or m in its filename.
            with open(out_path, "w") as f:
                _json.dump({"lines": picked, "quests": sorted(quests),
                            "gender": "f" if fcount >= mcount else "m",
                            "v": EXAMPLES_CACHE_VERSION}, f)
            print(f"[tts] {slug}: {len(picked)} dialogue examples, "
                  f"{len(quests)} quest(s) cached", flush=True)
    except Exception as e:
        print(f"[tts] example harvest failed for {slug}: {e}", flush=True)
    finally:
        _sh.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
#  Stage-direction -> animation. AMM ships a database of ~1000 named workspot
#  animations (auto-growing as the user installs pose packs), and the model's
#  own stage direction ("I say, looking the stranger over, arms crossed") is
#  a ready-made search query. Token overlap with substring stemming - "looking"
#  matches "look", "crossed" matches "cross" - scored per name, standing talk
#  loops preferred. Cached per rig, re-read when the db file changes so new
#  packs just appear.
# ---------------------------------------------------------------------------
ANIM_CACHE = {"mtime": 0.0, "rigs": {}}

# Never picked regardless of match: needs furniture, a second actor, moves
# the NPC, or is a combat pose.
ANIM_EXCLUDE = ("synced", "sit", "lying", "lie_", "photo", "vehicle",
                "phone", "bed_", "chair", "sofa", "couch", "floor",
                "ground", "walk", "sprint", "sleep", "aim", "melee",
                "reload", "barstool", "stairs", "car_", "wheel", "cover")
ANIM_STOPWORDS = {"the", "and", "her", "his", "their", "them", "with", "a",
                  "an", "as", "at", "of", "to", "i", "you", "up", "down",
                  "out", "off", "in", "on", "then", "she", "he", "they",
                  "says", "say", "said", "stranger", "player", "slightly",
                  "briefly", "while", "before", "after"}

# Direction-English -> the vocabulary the anim NAMES actually use. Built from
# a dump of the installed database's 2269 distinct name tokens (25k anims,
# base game conventions + pose packs), so every target word is real:
# look(977) crossed(1658) shrug(204) yes/nod(204) chin(183) describe(317)
# nervous(230) happy(145) cigarette(1080) drink(415) scratch(204) rub(170)...
ANIM_SYNONYMS = {
    "look": "look", "looks": "look", "looking": "look", "stare": "look",
    "stares": "look", "gaze": "look", "gazes": "look", "eyes": "look",
    "watches": "look", "watch": "look", "studies": "look", "sizes": "look",
    "glance": "look", "glances": "look",
    "cross": "crossed", "crosses": "crossed", "crossed": "crossed",
    "fold": "folded", "folds": "folded", "folded": "folded",
    "shrug": "shrug", "shrugs": "shrug",
    "nod": "yes", "nods": "yes",
    "think": "chin", "thinks": "chin", "ponder": "chin", "ponders": "chin",
    "considers": "chin", "muses": "chin", "strokes": "chin",
    "explain": "describe", "explains": "describe", "describe": "describe",
    "describes": "describe", "gestures": "gesture", "gesture": "gesture",
    "gesticulates": "gesture",
    "angry": "angry", "snaps": "angry", "scowls": "angry", "glares": "angry",
    "furious": "angry", "growls": "aggressive", "threatens": "aggressive",
    "nervous": "nervous", "nervously": "nervous", "fidgets": "nervous",
    "anxious": "nervous", "uneasy": "nervous", "shifts": "nervous",
    "laughs": "happy", "laugh": "happy", "chuckles": "happy",
    "grins": "happy", "smiles": "happy", "beams": "happy",
    "smokes": "cigarette", "smoke": "cigarette", "drag": "cigarette",
    "puffs": "cigarette",
    "drinks": "drink", "drink": "drink", "sips": "drink", "swigs": "drink",
    "lean": "lean", "leans": "lean", "leaning": "lean",
    "scratches": "scratch", "scratch": "scratch",
    "rubs": "rub", "rub": "rub",
    "points": "point", "point": "point", "waves": "wave", "wave": "wave",
    "pockets": "pocket", "checks": "check", "check": "check",
    "dances": "dance", "sways": "dance",
    "drunk": "drunk", "wobbles": "drunk",
    "eats": "eat", "chews": "eat",
    "holds": "hold", "grips": "hold",
    "nostalgic": "nostalgic", "wistful": "nostalgic", "remembers": "nostalgic",
    "sad": "sad", "sighs": "sad", "sombre": "sad", "somber": "sad",
    # Performatives - all verified present in the installed vocabulary
    # ("twirl" is not, "spin" is; the rest are exact)
    "twirl": ("spin", "dance"), "twirls": ("spin", "dance"),
    "twirling": ("spin", "dance"), "spins": ("spin", "dance"),
    "spin": ("spin", "dance"), "whirls": ("spin", "dance"),
    "bows": "bow", "bow": "bow", "salutes": "salute", "salute": "salute",
    "claps": "clap", "clap": "clap", "cheers": "cheer", "cheer": "cheer",
    "kisses": "kiss", "kiss": "kiss", "prays": "pray", "pray": "pray",
    "begs": "beg", "beg": "beg", "stretches": "stretch",
    "stretch": "stretch", "yawns": "yawn", "yawn": "yawn",
    "squats": "squat", "jumps": "jump", "jump": "jump",
    "poses": "pose", "pose": "pose",
    # -ing forms the model actually writes
    "thinking": "chin", "wondering": "chin", "crossing": "crossed",
    "folding": "folded", "shrugging": "shrug", "nodding": "yes",
    "laughing": "happy", "smiling": "happy", "grinning": "happy",
    "smoking": "cigarette", "drinking": "drink", "sipping": "drink",
    "scratching": "scratch", "rubbing": "rub", "pointing": "point",
    "waving": "wave", "checking": "check", "dancing": "dance",
    "eating": "eat", "holding": "hold", "glaring": "angry",
    "staring": "look", "sighing": "sad", "chuckling": "happy",
    "explaining": "describe", "gesturing": "gesture",
}

# Matching one of these carries real meaning; matching 'talk' or 'front'
# does not. Semantic hits score double, and only semantic weight can reach
# the trigger threshold - a graze on generic tokens picks nothing, and NO
# pick is always better than a wrong one (the game falls back to a plain
# talk loop).
# A performative the direction EXPLICITLY names (bows, claps, twirls)
# outranks incidental mood words ("laughing" must not beat "twirl").
ANIM_PERFORMATIVE = {"spin", "bow", "salute", "clap", "cheer", "kiss",
                     "pray", "beg", "stretch", "yawn", "squat", "jump",
                     "pose", "dance", "wave", "point"}
# VIBE over literalism (owner direction): embodied-expressive words and
# moods count; incidental fidgets (check, rub, scratch, pocket, hold, eat,
# drink) were matching too literally and are demoted to generic weight -
# they can no longer drive a pick on their own.
ANIM_SEMANTIC = {"look", "crossed", "folded", "shrug", "yes", "chin",
                 "describe", "gesture", "angry", "aggressive", "nervous",
                 "happy", "lean", "dance", "drunk", "nostalgic", "sad",
                 "argue", "explain",
                 "spin", "bow", "salute", "clap", "cheer", "kiss", "pray",
                 "beg", "stretch", "yawn", "squat", "jump", "pose", "wave",
                 "point"}


def _anim_db_path():
    return os.path.join(ARGS.game_dir, "bin", "x64", "plugins",
                        "cyber_engine_tweaks", "mods", "AppearanceMenuMod",
                        "db.sqlite3")


def _anim_names(rig: str):
    path = _anim_db_path()
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return []
    if mtime != ANIM_CACHE["mtime"]:
        ANIM_CACHE["rigs"] = {}
        ANIM_CACHE["mtime"] = mtime
    if rig not in ANIM_CACHE["rigs"]:
        import sqlite3
        try:
            con = sqlite3.connect(path)
            rows = con.execute(
                "SELECT anim_name FROM workspots WHERE anim_rig = ?",
                (rig,)).fetchall()
            con.close()
        except Exception:
            return []
        ANIM_CACHE["rigs"][rig] = [
            r[0] for r in rows
            if not any(x in r[0] for x in ANIM_EXCLUDE)]
    return ANIM_CACHE["rigs"][rig]


# Poses built around a prop the workspot system will not actually spawn -
# an invisible can or tablet reads as mime, never as charm. Excluded ALWAYS
# (field-caught: 'Look, I'm busy' picked rh_can__look_right - holding air).
ANIM_PROP_POSES = ("cigarette", "bottle", "tablet", "guitar", "glass",
                   "can_", "drink_", "purse", "tool", "cup")
# Two-handed actions that are merely impossible while holding something.
ANIM_HANDS_BUSY = ("clap", "eat")


# Furniture and scene props the workspot will not spawn. These were filtered
# out of the FALLBACK pool but not the MATCH path, and the divergence showed
# up in the field exactly as you would expect: a beat saying "leans in
# conspiratorially" matched a bar-leaning, hand-on-the-bar loop and played it
# for a clothing vendor with no bar in sight - authored scene anims that also
# carry their own baked dialogue audio, so she appeared to talk on her own.
# One pool, both paths, no divergence.
ANIM_SCENE_FURNITURE = ("lean", "bar_", "_bar", "table", "sink", "door",
                        "wall", "rail", "counter", "keyboard", "machine",
                        "window", "crate", "chair", "bed", "couch", "car_",
                        "bike", "wheel", "fence")


def usable_anims(rig: str, held: bool = False):
    names = [n for n in _anim_names(rig)
             if not any(f in n for f in ANIM_SCENE_FURNITURE)
             and not any(p in n for p in ANIM_PROP_POSES)
             and "glitch" not in n and "cyberspace" not in n
             and "npc1" not in n and "npc2" not in n
             and "gun" not in n and "weapon" not in n and "chip" not in n]
    if held:
        names = [n for n in names
                 if not any(x in n for x in ANIM_HANDS_BUSY)]
    return names


def cached_gender(voice: str) -> str:
    """What the character's own voice files say, when the game has no idea."""
    if not (voice and ARGS.game_dir):
        return ""
    path = os.path.join(ARGS.game_dir, "r6", "storages", "StreetTalk",
                        f"examples_{voice_forge.slugify(voice)}.json")
    try:
        with open(path) as f:
            g = json.load(f).get("gender", "")
            if g:
                return g
    except Exception:
        pass
    # Not harvested yet - ask the archive directly (cached after the first ask).
    if ARGS.wolvenkit:
        try:
            return voice_forge.speaker_gender(
                voice, ARGS.game_dir, ARGS.wolvenkit,
                os.path.join(ARGS.voices, "speaker_gender.json"),
                log=lambda m: print(m, flush=True))
        except Exception:
            pass
    return ""


def find_anim(direction: str, gender: str, held: bool = False) -> str:
    g = gender.lower()
    rig = "Woman Average" if g.startswith("f") else (
        "Man Average" if g.startswith("m") else "")
    if not rig:
        return ""
    # No beat at all - the model skipped it this turn. That is not a reason to
    # stand still: take a conversational loop from the same pool a no-match
    # would use, so a gesture always plays and it is never one of a handful of
    # repeats.
    if not direction.strip():
        return fallback_anim(rig)
    names = usable_anims(rig, held)
    if not names:
        return ""
    dtoks = set()
    for w in re.findall(r"[a-z]{3,}", direction.lower()):
        if w in ANIM_STOPWORDS:
            continue
        m = ANIM_SYNONYMS.get(w, w)
        if isinstance(m, tuple):
            dtoks.update(m)
        else:
            dtoks.add(m)
    if not dtoks:
        return ""
    best, best_score, best_sem = "", 0, 0
    for name in names:
        ntoks = {t for t in re.split(r"[_\W]+", name.lower()) if len(t) >= 3}
        score, sem = 0, 0
        for d in dtoks:
            # substring stemming both ways, but short name tokens must not
            # hide inside direction words ("lap" living inside "clap" once
            # outscored every real clap animation - self-test catch)
            hit = any(d == n or (len(d) >= 4 and d in n)
                      or (len(n) >= 5 and n in d)
                      for n in ntoks)
            if hit:
                if d in ANIM_PERFORMATIVE:
                    score += 3
                    sem += 1
                else:
                    if d in ANIM_SEMANTIC:
                        score += 2
                        sem += 1
                    else:
                        score += 1
        if score == 0:
            continue
        if "talk" in name:
            score += 1          # conversational loops win ties
        if "stand" in name:
            score += 1          # standing beats needs-a-prop poses
        if (score > best_score
                or (score == best_score and len(name) < len(best))):
            best, best_score, best_sem = name, score, sem
    # At least one MEANINGFUL word must have matched, and with enough
    # support that it is not a one-word graze.
    # Direct performatives trigger readily; everything else needs the
    # strength of a proper conversational match (mood + talk + stand), so
    # a lone literal word can never hijack the pose.
    threshold = 3 if any(d in ANIM_PERFORMATIVE for d in dtoks) else 4
    if best_sem >= 1 and best_score >= threshold:
        if LOG_CONTENT:
            print(f"[tts] anim match: '{direction[:60]}' -> {best}", flush=True)
        else:
            print(f"[tts] anim match -> {best}", flush=True)
        return best
    # THE OBSERVATIONAL LOOP: the directions the search cannot serve are the
    # ready-made list of next thesaurus entries - but they are also the
    # player's conversation, so the words only appear with content logging
    # explicitly enabled (STREETTALK_LOG_CONTENT=1).
    if LOG_CONTENT:
        print(f"[tts] anim no-match: '{direction[:80]}' "
              f"(tokens: {' '.join(sorted(dtoks))})", flush=True)
    else:
        print(f"[tts] anim no-match ({len(dtoks)} tokens)", flush=True)
    # NO MATCH IS NOT NO ANIMATION. Most ordinary conversation names no
    # action at all, and that is exactly when the whole installed catalogue
    # should be in play - a handful of hardcoded names is the one thing this
    # design exists to avoid. Draw a conversational standing loop from the
    # full filtered pool for this rig (hundreds of them, more with every pose
    # pack), at random so a long conversation never repeats itself.
    return fallback_anim(rig)


# Cached per rig: the conversational subset of the pool. "talk" or
# "conversation" in the name, standing, no props, single actor - the same
# filters the search uses, minus the semantics.
ANIM_TALK_POOL = {}


def fallback_anim(rig: str) -> str:
    import random
    pool = ANIM_TALK_POOL.get(rig)
    if pool is None or not pool:
        pool = [n for n in usable_anims(rig)
                if ("talk" in n or "conversation" in n) and "stand" in n]
        ANIM_TALK_POOL[rig] = pool
        print(f"[tts] anim fallback pool for {rig}: {len(pool)} loops",
              flush=True)
    if not pool:
        return ""
    pick = random.choice(pool)
    print(f"[tts] anim fallback -> {pick}", flush=True)
    return pick


# ---------------------------------------------------------------------------
#  WHO IS THIS PERSON - according to the game itself.
#
#  Story context used to be hand-written, which covered three characters and
#  left everyone else a blank. But the game ships 60,000 strings of shards,
#  emails, messages and briefings, and the people in it are DESCRIBED there:
#  Blue Moon is "some Japanese pop singer" in a stranger's text message; Judy
#  turns up in Mox mail about Clouds. So the same trick as the voices and the
#  animations - read the player's own install, cache the result - gives every
#  named character a background nobody had to write.
#
#  Deliberately conservative: only entries that read like description, only a
#  couple of them, truncated. It is background colour, not a wiki.
# ---------------------------------------------------------------------------
ONSCREENS = []          # every localized string in the game, loaded once
ONSCREENS_LOCK = threading.Lock()
BIO_DONE = set()

_IMPERATIVE = ("go to", "call ", "meet ", "wait for", "talk to", "find ",
               "head to", "follow ", "return to", "speak to")
_DESCRIPTIVE = ("singer", "star", "band", "known", "famous", "member", "idol",
                "fans", "netrunner", "merc", "fixer", "ripperdoc", "gang",
                "boss", "owner", "runs ", "works", "reputation", "legend")


def _load_onscreens():
    """Extract and index the game's localized text once, then cache it."""
    global ONSCREENS
    if ONSCREENS:
        return ONSCREENS
    cache = os.path.join(ARGS.voices, "onscreens_index.json")
    if os.path.isfile(cache):
        try:
            with open(cache) as f:
                ONSCREENS = json.load(f)
            return ONSCREENS
        except Exception:
            pass
    if not (ARGS.wolvenkit and ARGS.game_dir):
        return []
    archs = voice_forge.text_archives(ARGS.game_dir)
    if not archs:
        return []
    import glob as _glob
    import shutil as _sh
    import subprocess as _sp
    import tempfile as _tf
    env = dict(os.environ, DOTNET_ROLL_FORWARD="LatestMajor")
    tmp = _tf.mkdtemp(prefix="stbio_")
    try:
        for arch in archs:
            _sp.run([ARGS.wolvenkit, "unbundle", arch, "-o", tmp,
                     "-w", "*onscreens_final.json"],
                    capture_output=True, text=True, env=env, timeout=600)
        src = next(iter(_glob.glob(os.path.join(tmp, "**", "onscreens_final.json"),
                                   recursive=True)), None)
        if not src:
            return []
        _sp.run([ARGS.wolvenkit, "convert", "serialize", src],
                capture_output=True, text=True, env=env, timeout=300)
        with open(src + ".json") as f:
            data = json.load(f)
        entries = data["Data"]["RootChunk"]["root"]["Data"]["entries"]
        out = []
        for e in entries:
            for k in ("femaleVariant", "maleVariant"):
                v = e.get(k)
                if isinstance(v, dict):
                    v = v.get("$value", "")
                if isinstance(v, str) and 60 <= len(v) <= 700:
                    out.append(v)
                    break
        ONSCREENS = out
        try:
            with open(cache, "w") as f:
                json.dump(out, f)
        except Exception:
            pass
        print(f"[tts] indexed {len(out)} lines of the game's own text", flush=True)
        return ONSCREENS
    except Exception as e:
        print(f"[tts] could not index game text: {e}", flush=True)
        return []
    finally:
        _sh.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
#  THE WIKI, and why it is OFF unless you turn it on.
#
#  The community wiki knows what the game's own strings only imply: Blue Moon's
#  page states her role (Japanese idol), her band (Us Cracks), where she is
#  from, and describes her as "the poet of the band, always lost in thought".
#  That is a character card written by people who care, and it exists for
#  nearly everyone with a name.
#
#  But fetching it is a NETWORK REQUEST, and this mod's whole promise is that
#  nothing leaves your machine. So it is opt-in, off by default, and when it is
#  off not one byte is sent. When it is on, the only thing transmitted is a
#  character name to a public wiki - the same request a browser makes.
#
#  Only the LEAD section is read (section=0): biography, not plot. Death and
#  status fields are dropped outright, since "date of death" is the one
#  spoiler nobody wants handed to them by a shopkeeper.
#
#  Nothing is redistributed: the text is fetched by the player's own machine
#  and cached locally, and the wiki is credited in the README (CC BY-SA).
# ---------------------------------------------------------------------------
WIKI_FIELDS = ("role", "occupation", "affiliation", "aka", "home",
               "place_of_birth", "nationality", "gang")
WIKI_SKIP = ("status", "dod", "place_of_death", "death")


def _strip_templates(t: str) -> str:
    """Remove {{...}} even when nested - a single regex pass leaves the outer
    braces of an infobox behind, which then reads as garbage in the card."""
    out, depth, i = [], 0, 0
    while i < len(t):
        if t.startswith("{{", i):
            depth += 1
            i += 2
        elif t.startswith("}}", i):
            depth = max(0, depth - 1)
            i += 2
        else:
            if depth == 0:
                out.append(t[i])
            i += 1
    return "".join(out)


def _wiki_clean(t: str) -> str:
    t = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]?\]?", r"\1", t)   # links, even unclosed
    t = re.sub(r"'{2,}", "", t)
    t = re.sub(r"<[^>]+>", " ", t)
    t = re.sub(r"\(pg\.?[^)]*\)", " ", t)                      # sourcebook page refs
    t = re.sub(r"\s+", " ", t)
    return t.strip(" |")


def _wiki_fetch(page: str):
    import urllib.parse
    import urllib.request
    url = ("https://cyberpunk.fandom.com/api.php?action=parse&prop=wikitext"
           "&section=0&redirects=1&format=json&page=" + urllib.parse.quote(page))
    req = urllib.request.Request(url, headers={
        "User-Agent": "StreetTalk-Cyberpunk2077-mod (local character lookup)"})
    with urllib.request.urlopen(req, timeout=12) as r:
        data = json.load(r)
    return data.get("parse", {}).get("wikitext", {}).get("*", "")


def _wiki_search(name: str):
    """Titles do not always match the game's spelling - the game says Viktor
    Vector, the wiki says Vektor - so a miss falls back to search."""
    import urllib.parse
    import urllib.request
    url = ("https://cyberpunk.fandom.com/api.php?action=query&list=search"
           "&srlimit=1&format=json&srsearch=" + urllib.parse.quote(name))
    req = urllib.request.Request(url, headers={
        "User-Agent": "StreetTalk-Cyberpunk2077-mod (local character lookup)"})
    with urllib.request.urlopen(req, timeout=12) as r:
        data = json.load(r)
    hits = data.get("query", {}).get("search", [])
    return hits[0]["title"] if hits else ""


def wiki_bio(display_name: str):
    """The character's lead section from the community wiki. Returns [] on any
    problem at all - a lookup failing must never cost the player a reply."""
    try:
        wt = _wiki_fetch(display_name)
        if not wt or len(wt) < 80:
            alt = _wiki_search(display_name)
            if alt and alt.lower() != display_name.lower():
                wt = _wiki_fetch(alt)
                if wt:
                    print(f"[tts] wiki: '{display_name}' -> '{alt}'", flush=True)
        if not wt:
            return []
        lines = []
        # 1. the infobox facts worth having
        facts = []
        for m in re.finditer(r"\|\s*([a-z_]+)\s*=\s*([^|\n}]+)", wt):
            key, val = m.group(1).strip(), _wiki_clean(m.group(2))
            if key in WIKI_SKIP or key not in WIKI_FIELDS or not val:
                continue
            val = val.split("(")[0].strip()
            if 0 < len(val) < 50:
                facts.append(f"{key.replace('_', ' ')}: {val}")
        if facts:
            lines.append("; ".join(facts[:6]) + ".")
        # 2. the quoted character description, if the page has one
        q = re.search(r"Block Quote\s*\|\s*text\s*=\s*([^|}]+)", wt)
        if q:
            desc = _wiki_clean(q.group(1))
            if len(desc) > 30:
                lines.append(desc[:320])
        # 3. the lead prose, templates removed properly
        body = _wiki_clean(_strip_templates(wt))
        body = re.sub(r"^[^A-Za-z]+", "", body)
        if len(body) > 60:
            lines.append(body[:360])
        return lines
    except Exception as e:
        print(f"[tts] wiki lookup failed for {display_name}: {e}", flush=True)
        return []


def harvest_bio(display_name: str, slug: str, use_wiki: bool = False):
    """Write bio_<slug>.json: what the game's own text says about this person."""
    out_dir = os.path.join(ARGS.game_dir, "r6", "storages", "StreetTalk")
    out_path = os.path.join(out_dir, f"bio_{slug}.json")
    if os.path.isfile(out_path) or not os.path.isdir(out_dir):
        return
    name = (display_name or "").strip()
    # Generic labels ("NC Resident", "Stranger") describe nobody.
    if len(name) < 4 or name.lower() in ("stranger", "nc resident", "civilian"):
        return
    # The wiki first when allowed - it is written ABOUT the character, where
    # the game's strings only mention them in passing.
    if use_wiki:
        wl = wiki_bio(name)
        if wl:
            try:
                with open(out_path, "w") as f:
                    json.dump({"lines": wl, "source": "wiki"}, f)
                print(f"[tts] wiki background for {display_name}: "
                      f"{len(wl)} passage(s)", flush=True)
                return
            except Exception:
                pass

    with ONSCREENS_LOCK:
        corpus = _load_onscreens()
    if not corpus:
        return

    def scan(needle):
        needle_l = needle.lower()
        found = []
        for t in corpus:
            tl = t.lower()
            if needle_l not in tl:
                continue
            if any(tl.startswith(x) for x in _IMPERATIVE):
                continue
            score = 1 + sum(1 for w in _DESCRIPTIVE if w in tl)
            found.append((score, t))
        found.sort(key=lambda x: (-x[0], len(x[1])))
        return found

    hits = scan(name)
    if len(hits) < 2:
        # Full names often are not how people refer to each other - "Viktor
        # Vector" appears nowhere, "Viktor" does.
        first = name.split()[0]
        if len(first) >= 4:
            hits += scan(first)
    if not hits:
        return
    lines = []
    for _, t in hits[:3]:
        t = re.sub(r"\s+", " ", t).strip()
        lines.append(t[:260])
    try:
        with open(out_path, "w") as f:
            json.dump({"lines": lines}, f)
        print(f"[tts] background found for {display_name}: {len(lines)} passage(s)",
              flush=True)
    except Exception:
        pass


def maybe_harvest(slug: str, alias: str = ""):
    with EXAMPLES_LOCK:
        key = alias or slug
        if key in EXAMPLES_DONE:
            return
        EXAMPLES_DONE.add(key)
    threading.Thread(target=harvest_examples, args=(slug,),
                     kwargs={"alias": alias}, daemon=True).start()


def maybe_bio(display_name: str, slug: str, use_wiki: bool = False):
    with EXAMPLES_LOCK:
        if slug in BIO_DONE:
            return
        BIO_DONE.add(slug)
    threading.Thread(target=harvest_bio, args=(display_name, slug, use_wiki),
                     daemon=True).start()


def get_model():
    """Lazy-load so the server starts instantly; first request pays the cost."""
    global MODEL
    if MODEL is None:
        print("[tts] loading XTTS-v2 (first time also downloads ~2 GB) ...", flush=True)
        from TTS.api import TTS  # package: coqui-tts (maintained fork)
        MODEL = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(ARGS.device)
        print("[tts] model ready", flush=True)
    return MODEL


def voice_path(name: str) -> str | None:
    # The voice name comes from the game (NPC display name); strip anything
    # path-like so it can only ever select a file inside voices/.
    #
    # voices/ root = clips a human placed - overrides, never touched.
    # voices/forged/ = clips this server forged - re-forged automatically
    # whenever they fall below the current quality target, so improvements
    # (like the 18s -> 30s reference bump) roll out without anyone deleting
    # files by hand.
    safe = re.sub(r"[^A-Za-z0-9 _\-']", "", name or "").strip()
    for candidate in (safe, "default"):
        if not candidate:
            continue
        p = os.path.join(ARGS.voices, candidate + ".wav")
        if os.path.isfile(p):
            return p
        f = os.path.join(ARGS.voices, "forged", candidate + ".wav")
        if os.path.isfile(f):
            try:
                ver = int(open(f + ".ver").read().strip())
            except (OSError, ValueError):
                ver = 0
            if ver < voice_forge.FORGE_VERSION:
                print(f"[tts] {candidate}.wav from an older forge - "
                      f"re-forging once", flush=True)
                os.unlink(f)
                return None
            return f
    return None


def builtin_speaker(gender=""):
    """A built-in XTTS voice, used when no reference clip exists.

    Reference clips were originally REQUIRED, which meant voice did nothing
    at all until you went and recorded one - and failed silently when you
    hadn't. XTTS ships speaker embeddings, so there is no reason for the
    zero-setup path not to talk. Clips are now an upgrade, not a gate.
    """
    speakers = getattr(get_model(), "speakers", None) or []
    if not speakers:
        return None
    if ARGS.speaker and ARGS.speaker in speakers:
        return ARGS.speaker
    # at minimum, match the character's sex (a male bartender got the female
    # default before gender flowed through)
    gl = gender.lower()
    if gl.startswith("m"):
        pick = "Damien Black"
    elif gl.startswith("f"):
        pick = "Daisy Studious"
    else:
        pick = speakers[0]
    return pick if pick in speakers else speakers[0]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):  # quieter default logging
        print("[tts] " + fmt % a, flush=True)

    def _json(self, code: int, obj: dict):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"status": "ok"})
        return self._json(404, {"error": "unknown path"})

    def _next_chunk(self, req):
        """Continuation: the game asks for the next sentence of a reply,
        blocking until it is synthesized. Body: {next: id, slot: N}."""
        sid = req.get("next", "")
        slot = int(req.get("slot", 0)) % 4
        s = SESSIONS.get(sid)
        if not s:
            return self._json(410, {"error": "unknown session"})
        i = s["cursor"]
        s["cursor"] += 1
        if i >= len(s["chunks"]):
            return self._json(410, {"error": "past the end"})
        s["events"][i].wait(timeout=300)
        tmp = s["wavs"].get(i)
        if not tmp:
            return self._json(500, {"error": f"chunk {i} failed"})
        out = os.path.join(ARGS.slots, f"slot_{slot}.wav")
        dur = wav_ms(tmp)
        os.replace(tmp, out)
        more = 1 if s["cursor"] < len(s["chunks"]) else 0
        print(f"[tts] slot {slot} <- chunk {i + 1}/{len(s['chunks'])}", flush=True)
        return self._json(200, {"ok": 1, "slot": slot, "dur_ms": dur,
                                "more": more, "id": sid, "cont": 1,
                                "text": s["chunks"][i]})

    def _resolve_voice(self, req):
        """Shared voice resolution (clip -> forge -> builtin). Returns
        (voice_kw or None-for-disabled, label, error_json_or_None)."""
        if int(req.get("tts", 1)) == 0:
            return None, "off", None
        voice = req.get("voice", "")
        vtag = re.sub(r"[^A-Za-z0-9_]", "", req.get("voicetag", "")).lower()
        if vtag == "none":   # CName none stringifies to "None"
            vtag = ""
        crowd = bool(req.get("crowd", False))
        gender = req.get("gender", "")
        faction = req.get("faction", "")
        vkey = req.get("vkey", "")
        with FORGE_LOCK:
            return self._resolve_voice_locked(voice, vtag, crowd, gender,
                                              faction, vkey)

    def _resolve_voice_locked(self, voice, vtag, crowd, gender="", faction="",
                              vkey=""):
        speaker_slug = None
        FORGED_NOW[0] = False
        ref = voice_path(voice) or (voice_path(vtag) if vtag else None)
        if ref is None and ARGS.wolvenkit:
            logf = lambda m: print(m, flush=True)
            if not crowd and voice and voice not in FORGE_FAILED:
                safe = re.sub(r"[^A-Za-z0-9 _\-']", "", voice).strip()
                if safe:
                    out = os.path.join(ARGS.voices, "forged", safe + ".wav")
                    if voice_forge.forge(voice, out, ARGS.game_dir,
                                         ARGS.wolvenkit, ARGS.vgmstream,
                                         log=logf, gender=gender):
                        ref = out
                        FORGED_NOW[0] = True
                    else:
                        FORGE_FAILED.add(voice)
            if ref is None and vtag and vtag not in FORGE_FAILED:
                out = os.path.join(ARGS.voices, "forged", vtag + ".wav")
                if voice_forge.forge(vtag, out, ARGS.game_dir,
                                     ARGS.wolvenkit, ARGS.vgmstream,
                                     log=logf, slug_override=vtag):
                    ref = out
                    speaker_slug = vtag
                else:
                    FORGE_FAILED.add(vtag)
        # NEVER-GIVE-UP LADDER. Everyone with lines in the archive gets a
        # real voice; the built-in is for genuinely voiceless edge cases.
        if ref is None and ARGS.wolvenkit:
            roster = voice_forge.speaker_roster(
                ARGS.game_dir, ARGS.wolvenkit,
                os.path.join(ARGS.voices, "roster.json"),
                log=lambda m: print(m, flush=True))
            gl = gender.lower()
            g = "m" if gl.startswith("m") else ("f" if gl.startswith("f") else "")

            # 1. a display-name TOKEN that IS a speaker ("Pepe Najarro" ->
            #    pepe). Named characters with partial-name voice banks.
            cand = None
            for tok in voice_forge.slugify(voice).split("_"):
                if len(tok) >= 3 and roster.get(tok, 0) >= 5:
                    cand = tok
                    break
            # 2. an archetype bank matching gender (and faction when its
            #    first letters appear in a bank name - roster-driven, e.g.
            #    Valentinos -> gang_val_...). Stable hash of the NPC's name
            #    picks the variant, so the same person always sounds the
            #    same, and different people spread across the bank pool.
            if cand is None:
                fhint = re.sub(r"[^a-z]", "", faction.lower())[:3]
                banks = [s2 for s2, n in roster.items()
                         if n >= 30 and (not g or f"_{g}_" in s2)
                         and (s2.startswith("gang") or s2.startswith("civ"))
                         and "_vs_" not in s2
                         and (("_f_" in s2) != ("_m_" in s2))
                         and s2.count("civ_") + s2.count("gang_") <= 1]
                if not g:
                    print(f"[tts] {voice or 'npc'}: gender unknown - "
                          f"coin-flip bank pool", flush=True)
                pref = [b for b in banks if fhint and fhint in b] or banks
                if pref:
                    idx = sum(ord(c) for c in (vkey or voice)) % len(pref)
                    cand = sorted(pref)[idx % len(pref)]
            if cand and cand not in FORGE_FAILED:
                out = os.path.join(ARGS.voices, "forged", cand + ".wav")
                had = os.path.isfile(out)
                if had or voice_forge.forge(
                        cand, out, ARGS.game_dir, ARGS.wolvenkit,
                        ARGS.vgmstream, log=lambda m: print(m, flush=True),
                        slug_override=cand):
                    ref = out
                    if not had:
                        FORGED_NOW[0] = True
                    speaker_slug = cand
                    print(f"[tts] {voice or 'npc'}: assigned archive voice "
                          f"'{cand}'", flush=True)
                else:
                    FORGE_FAILED.add(cand)

        if ref is not None:
            base = os.path.basename(ref)[:-4]
            if ARGS.wolvenkit and ARGS.game_dir:
                spk = speaker_slug
                if not spk and (voice or vtag):
                    roster = voice_forge.speaker_roster(
                        ARGS.game_dir, ARGS.wolvenkit,
                        os.path.join(ARGS.voices, "roster.json"),
                        log=lambda m: print(m, flush=True))
                    # THE GAME'S OWN VOICE TAG WINS. Some characters are filed
                    # under an internal codename no name-matching can reach:
                    # River Ward's 1157 lines are all under "sobchak", 262 of
                    # them in his own questline, and "River"/"Ward" match
                    # nothing at all. The record's VoiceTag knows - the mod
                    # already sends it for the voice - so ask it first and stop
                    # guessing from display names.
                    if vtag and roster.get(vtag, 0) > 0:
                        spk = vtag
                        print(f"[tts] {voice or 'npc'}: archive speaker "
                              f"'{vtag}' (from the game's voice tag)", flush=True)
                    elif voice:
                        spk = voice_forge.resolve_speaker(voice, roster)
                spk = spk or (voice_forge.slugify(voice) if voice else base)
                maybe_harvest(spk, alias=voice_forge.slugify(voice) if voice else "")
                # NOT here: background lookups are a chat-open job, never
                # something that happens between two lines of a conversation.
            return {"speaker_wav": ref}, os.path.basename(ref), None
        spk = builtin_speaker(gender)
        if spk is None:
            return None, "", {"error": "no voice available"}
        return {"speaker": spk}, f"built-in:{spk}", None

    def do_POST(self):
        if self.path != "/speak":
            return self._json(404, {"error": "unknown path"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(length) or b"{}")
            # The game's switch drives this server's verbosity too.
            if req.get("cond"):
                want = max(6, min(30, int(req.get("cond"))))
                if want != COND_SECONDS[0]:
                    COND_SECONDS[0] = want
                    LAT_CACHE.clear()
                    print(f"[tts] voice detail set to {want}s", flush=True)
            # Throw away every cloned voice: the next conversation rebuilds
            # whoever it needs from the game files again.
            if req.get("reset_voices"):
                import glob as _g
                import shutil as _sh
                n = 0
                for path in _g.glob(os.path.join(ARGS.voices, "forged", "*")):
                    try:
                        if os.path.isdir(path):
                            _sh.rmtree(path, ignore_errors=True)
                        else:
                            os.remove(path)
                        n += 1
                    except Exception:
                        pass
                LAT_CACHE.clear()
                FORGE_FAILED.clear()
                print(f"[tts] rebuild requested: {n} cached voice file(s) removed",
                      flush=True)
                return self._json(200, {"ok": 1, "removed": n})
            if "wiki" in req:
                WIKI_OK[0] = bool(req.get("wiki"))
            if "log" in req:
                global LOG_CONTENT
                LOG_CONTENT = bool(req.get("log")) or (
                    os.environ.get("STREETTALK_LOG_CONTENT", "") == "1")
            # Character background, asked for once when the chat opens. Runs
            # SYNCHRONOUSLY so the game can wait for it and build the card
            # with the biography already in it - a card that arrives after the
            # first reply is a card that missed its moment.
            if req.get("bio"):
                name = (req.get("voice") or "").strip()
                if name:
                    try:
                        harvest_bio(name, voice_forge.slugify(name),
                                    bool(req.get("wiki")))
                    except Exception as e:
                        print(f"[tts] bio failed: {e}", flush=True)
                return self._json(200, {"ok": 1})
            if req.get("prep"):
                # Warm-up at chat open: forge if needed, compute conditioning.
                # Responds only when the voice is fully ready, so the game
                # knows when to drop its "learning their voice" indicator.
                if req.get("diag"):
                    # The game's own introspection snapshot (record, template
                    # path, appearance, raw gender). Printed here because THIS
                    # log is always on, while the in-game one is opt-in.
                    print(f"[tts] {req.get('voice') or 'npc'}: game says "
                          f"{req['diag']}", flush=True)
                kw, label, err = self._resolve_voice(req)
                if err is not None:
                    return self._json(503, err)
                if kw and kw.get("speaker_wav"):
                    with MODEL_LOCK:
                        get_latents(get_model().synthesizer.tts_model, kw["speaker_wav"])
                print(f"[tts] voice ready: {label}", flush=True)
                # forged=0 means it was already on disk: the game must not tell
                # the player it is learning a voice it has had for days.
                return self._json(200, {"ok": 1, "voice": label,
                                        "forged": 1 if FORGED_NOW[0] else 0})
            if req.get("next"):
                return self._next_chunk(req)
            text = (req.get("text") or "").strip()
            direction = (req.get("direction") or "").strip()
            slot = int(req.get("slot", 0)) % 4
            if not text:
                return self._json(400, {"error": "no text"})

            voice_kw, label, err = self._resolve_voice(req)
            if err is not None:
                return self._json(503, err)
            if voice_kw is None:
                return self._json(400, {"error": "tts disabled in request"})

            chunks = split_sentences(text)
            # The game asks for a quieter mix for V's own lines.
            gain = float(req.get("gain", 1.0) or 1.0)
            gain = min(max(gain, 0.05), 1.0)
            if not (req.get("gender") or "").strip():
                req["gender"] = cached_gender(req.get("voice", ""))
            tmp = synth_to_tmp(chunks[0], voice_kw, gain)
            out = os.path.join(ARGS.slots, f"slot_{slot}.wav")
            dur = wav_ms(tmp)
            os.replace(tmp, out)

            sid = ""
            more = 0
            if len(chunks) > 1:
                sid = uuid.uuid4().hex[:8]
                more = 1
                with SESSIONS_LOCK:
                    SESSIONS[sid] = {
                        "chunks": chunks, "kw": voice_kw, "cursor": 1,
                        "gain": gain,
                        "wavs": {}, "events": {i: threading.Event()
                                               for i in range(1, len(chunks))},
                    }
                    while len(SESSIONS) > MAX_SESSIONS:
                        SESSIONS.pop(next(iter(SESSIONS)))
                threading.Thread(target=chunk_worker, args=(sid,),
                                 daemon=True).start()

                # THE GAPLESS GATE. Hold this response - which is what starts
                # playback - until the speech already synthesized will outlast
                # the projected time to synthesize the rest. Playback then
                # never catches up to synthesis and chunks butt together.
                # THE GATE, corrected. The old criterion demanded banked
                # audio cover ALL remaining synthesis - that is full
                # prefetch, and it cost up to 8s of dead air. What actually
                # prevents a stall is covering the DEFICIT: synthesis runs
                # at SPEED x realtime, so while N seconds of speech plays,
                # synthesis falls behind by N*(SPEED-1). Hold only that
                # much (plus a small margin) and playback never catches up.
                # For a 12s reply at 1.15x that is ~1.8s, not 12s.
                import time as _time
                held = 0.0
                sess = SESSIONS[sid]
                while held < 4.0:
                    banked = dur / 1000.0 + sum(
                        wav_ms(pp) / 1000.0 for pp in sess["wavs"].values())
                    left = [c for i, c in enumerate(chunks)
                            if i > 0 and i not in sess["wavs"]]
                    if not left:
                        break
                    play_left = sum(len(c) for c in left) * SPC[0]
                    deficit = play_left * max(0.0, SPEED[0] - 1.0) + 0.4
                    if banked >= deficit:
                        break
                    _time.sleep(0.2)
                    held += 0.2
                if held > 0:
                    print(f"[tts] gate held {held:.1f}s", flush=True)

            print(f"[tts] slot {slot} <- chunk 1/{len(chunks)} "
                  f"({label})" + (f": {chunks[0]}" if LOG_CONTENT else ""),
                  flush=True)
            return self._json(200, {"ok": 1, "slot": slot, "dur_ms": dur,
                                    "more": more, "id": sid, "cont": 0,
                                    "text": chunks[0],
                                    "anim": find_anim(
                                        direction, req.get("gender", ""),
                                        bool(req.get("held")))})
        except Exception as e:  # surface errors to the log, fail the request
            print(f"[tts] ERROR: {e}", flush=True)
            return self._json(500, {"error": str(e)})


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--slots", required=True,
                    help="game's r6/audioware/StreetTalk/slots directory")
    ap.add_argument("--voices", required=True,
                    help="directory of <Display Name>.wav reference clips")
    ap.add_argument("--port", type=int, default=8082)
    ap.add_argument("--device", default="cpu", choices=["cpu", "cuda"],
                    help="cpu default: the GPU already runs the game + LLM")
    ap.add_argument("--speaker", default="",
                    help="built-in XTTS speaker name, last-resort fallback")
    ap.add_argument("--game-dir", default="",
                    help="Cyberpunk 2077 directory (enables voice forging)")
    ap.add_argument("--wolvenkit", default="",
                    help="WolvenKit CLI binary (enables voice forging)")
    ap.add_argument("--vgmstream", default="",
                    help="vgmstream-cli binary (enables voice forging)")
    ARGS = ap.parse_args()

    if not os.path.isdir(ARGS.slots):
        sys.exit(f"[tts] slots dir missing: {ARGS.slots} - is the mod deployed?")
    os.makedirs(os.path.join(ARGS.voices, "forged"), exist_ok=True)

    # Fail LOUD at startup instead of answering /health and then dying on the
    # first real request - which is exactly how this went unnoticed.
    try:
        import torch  # noqa: F401
        from TTS.api import TTS  # noqa: F401
    except Exception as e:
        sys.exit(f"[tts] FATAL: TTS stack unusable ({e}).\n"
                 f"      Delete .venv next to this script and run "
                 f"npc-tts-server.sh again.")

    clips = [f for f in os.listdir(ARGS.voices) if f.lower().endswith(".wav")]
    if clips:
        print(f"[tts] voice clips: {', '.join(sorted(clips))}", flush=True)
    if ARGS.wolvenkit and os.path.isfile(ARGS.wolvenkit):
        print("[tts] voice forging ON: characters without a clip get their "
              "real voice extracted from your game archives on first talk",
              flush=True)
    else:
        print("[tts] voice forging OFF (no --wolvenkit) - unknown characters "
              "fall back to a built-in voice", flush=True)

    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print(f"[tts] listening on 127.0.0.1:{ARGS.port} "
          f"(slots: {ARGS.slots})", flush=True)
    # Pre-warm in the background: model load is ~10s and used to be paid by
    # the FIRST spoken line of every session. The launcher starts this server
    # before the game even reaches the menu, so the cost disappears entirely.
    threading.Thread(target=get_model, daemon=True).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
