#!/usr/bin/env python3
"""Beat -> action classification bench.

Same test, swappable model (any OpenAI-compatible endpoint) and swappable
naming scheme. Scored two ways:
  strict  - the single label I consider right
  lenient - any label a reasonable person could defend for that line
"""
import argparse, json, time, urllib.request

# --- the action list, in two naming schemes -------------------------------
# EXPLICIT spells the relation out; VERB hides the relation inside one word.
COMMON = """follow: goes with V
stay_here: stops walking with V, waits, holds position
leave: walks off, ends the conversation
run: flees, runs away in fear
step_back: backs off, gives V space
step_closer: comes nearer to V
drop_item: puts down or drops what they are holding
draw_weapon: pulls out a gun or blade
holster: puts their weapon away
attack: opens fire on someone, starts a fight
sit: sits down
stand: stands up
lean: leans on something
crouch: crouches or ducks
point_at: points at something or someone
wave: waves
hug: embraces V
push: shoves someone
laugh: laughs
smoke: lights or smokes a cigarette
drink: drinks something
look_around: scans the area, checks surroundings
nod: nods
shake_head: shakes their head no
shrug: shrugs
cross_arms: folds their arms
check_phone: looks at their phone, holo, agent or takes a call
get_in_vehicle: gets into a car
reload: reloads a weapon
search: searches a container or body"""

EXPLICIT = COMMON + """
give_money_to_v: hands money TO V
take_money_from_v: takes money FROM V, asks V to pay
protect_v: covers V, backs V up, puts themselves between V and danger
turn_toward_v: turns to face V
turn_back_on_v: turns their back on V"""

VERB = COMMON + """
tip: pays V, hands over eddies
charge: bills V, demands payment, asks for eddies
guard: covers V, shields V, puts themselves between V and danger
face: turns to face V
snub: turns their back on V"""

MAP = {  # verb-scheme id -> explicit-scheme id, so one answer key serves both
    "tip": "give_money_to_v", "charge": "take_money_from_v",
    "guard": "protect_v", "face": "turn_toward_v", "snub": "turn_back_on_v",
}

# --- the test set ----------------------------------------------------------
# (beat, strict answer, also-acceptable answers)
CASES = [
 ("backs away slowly", "step_back", []),
 ("backs him up, weapon raised", "protect_v", ["attack", "draw_weapon"]),
 ("backs off, hands up", "step_back", []),
 ("puts it down on the bar", "drop_item", []),
 ("puts her rifle down", "drop_item", []),
 ("puts her drink down and stands", "stand", ["drop_item"]),
 ("takes off down the alley", "run", ["leave"]),
 ("takes off her jacket", None, []),
 ("takes a step toward V", "step_closer", []),
 ("falls in beside V", "follow", []),
 ("stays where she is", "stay_here", []),
 ("waits by the truck", "stay_here", []),
 ("walks off without another word", "leave", []),
 ("departs without a word", "leave", []),
 ("bolts for the door", "run", ["leave"]),
 ("draws her Overwatch", "draw_weapon", []),
 ("slides the pistol back into its holster", "holster", []),
 ("levels the rifle at the guy and fires", "attack", []),
 ("steps in front of V, gun up", "protect_v", ["draw_weapon", "attack"]),
 ("counts out a few hundred eddies and hands them over", "give_money_to_v", []),
 ("slides a stack of eddies across the table to V", "give_money_to_v", []),
 ("holds out a hand for the money", "take_money_from_v", []),
 ("names her price and waits", "take_money_from_v", []),
 ("drops into the chair", "sit", []),
 ("leans back against the wall", "lean", []),
 ("ducks behind the crates", "crouch", []),
 ("jabs a finger at the corpo", "point_at", []),
 ("throws V a lazy wave", "wave", []),
 ("shoves him hard in the chest", "push", []),
 ("cracks up laughing", "laugh", []),
 ("lights a cigarette", "smoke", []),
 ("knocks back the rest of her beer", "drink", []),
 ("scans the street both ways", "look_around", []),
 ("turns to face V", "turn_toward_v", []),
 ("turns her back on V", "turn_back_on_v", []),
 ("crosses her arms", "cross_arms", []),
 ("checks her holo", "check_phone", []),
 ("climbs into the passenger seat", "get_in_vehicle", []),
 ("slaps a fresh magazine in", "reload", []),
 ("starts going through the dead guy's pockets", "search", []),
 ("shakes her head slowly", "shake_head", []),
 ("gives a small shrug", "shrug", []),
 # flavour: the right answer is nothing at all
 ("sighs and rubs her eyes", None, []),
 ("smiles faintly", None, []),
 ("says nothing for a moment", None, []),
 ("raises an eyebrow", None, []),
 ("looks V over", None, ["turn_toward_v"]),
 ("goes quiet, thinking", None, []),
]

PROMPT = ("You label a line of stage direction from a roleplay game with the one action "
          "it describes, if any.\n\nActions:\n{actions}\n\nMost stage directions are just "
          "flavour - a look, a sigh, a smile - and match nothing here. Answer 'none' "
          "unless the line clearly and unambiguously describes one of the actions above. "
          "Answer with the action id alone, or 'none'. One word, nothing else.")


def run(url, model, scheme, use_grammar=True):
    actions = VERB if scheme == "verb" else EXPLICIT
    ids = [l.split(":")[0] for l in actions.splitlines()] + ["none"]
    sysmsg = PROMPT.format(actions=actions)
    grammar = "root ::= " + " | ".join(f'"{i}"' for i in ids)

    strict = lenient = 0
    times, misses = [], []
    for beat, want, alt in CASES:
        payload = {"model": model, "temperature": 0.0, "max_tokens": 12,
                   "messages": [{"role": "system", "content": sysmsg},
                                {"role": "user", "content": beat}]}
        if use_grammar:
            payload["grammar"] = grammar
        t = time.time()
        r = urllib.request.urlopen(urllib.request.Request(
            url, json.dumps(payload).encode(), {"Content-Type": "application/json"}),
            timeout=300)
        got = json.load(r)["choices"][0]["message"]["content"].strip().lower()
        times.append(time.time() - t)
        got = got.split()[0].strip(".,'\"") if got else ""
        got = MAP.get(got, got)                      # normalise verb ids
        target = want or "none"
        ok = got == target
        okish = ok or got in [MAP.get(a, a) for a in alt]
        strict += ok
        lenient += okish
        if not okish:
            misses.append((beat, target, got))
    n = len(CASES)
    return {"strict": strict, "lenient": lenient, "n": n,
            "median_ms": sorted(times)[len(times) // 2] * 1000,
            "misses": misses}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8081/v1/chat/completions")
    ap.add_argument("--model", default="local")
    ap.add_argument("--scheme", default="explicit", choices=["explicit", "verb"])
    ap.add_argument("--no-grammar", action="store_true")
    a = ap.parse_args()
    res = run(a.url, a.model, a.scheme, not a.no_grammar)
    print(f"{a.scheme:8s} strict {res['strict']}/{res['n']} "
          f"({100*res['strict']/res['n']:.0f}%)  lenient {res['lenient']}/{res['n']} "
          f"({100*res['lenient']/res['n']:.0f}%)  median {res['median_ms']:.0f} ms")
    for b, w, g in res["misses"]:
        print(f"    {b!r} -> wanted {w}, got {g}")
