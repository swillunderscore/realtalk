#!/usr/bin/env python3
"""Merged menu: game actions + gestures + facial no-ops in ONE classifier call.

Tests three ideas at once:
 - Will's merged menu (classifier routes to game command OR animation search term)
 - Will's `charge_money` rename (direction + domain in the id)
 - the railroad fix (smile/frown/sigh on the menu as legal no-op exits)
Every gesture id maps to a search term verified to have hits in the AMM db
(Woman Average rig): lean 4392, crossed 916, sit 3962, phone 297, drink 228,
angry 190, dance 165, shrug 109, smoke 93, stretch 55, point 51, cry 50,
laugh 21, think 12, wave 10. smile/frown/etc have ZERO - facial is not a
workspot - so they map to no-op.
"""
import json, re, time, urllib.request

URL = "http://127.0.0.1:8081/v1/chat/completions"

MENU = """follow: goes with V, walks with V
stay_here: stops following, waits, holds position
leave: walks off, ends the conversation
run: flees, runs away
step_back: backs off, gives V space
step_closer: comes nearer to V
drop_item: puts down or drops what they are holding
holster: puts their weapon away
hand_over_weapon: gives their weapon to V
attack: opens fire, stabs, lunges, starts a fight
tip: hands eddies to V
charge_money: asks V for payment
laugh: laughs
shrug: shrugs
lean: leans on something
cross_arms: folds their arms
point: points at something or someone
light_cigarette: lights or smokes a cigarette
wave: waves
think: pauses to think
dance: dances, sways to music
sit: sits down
angry_gesture: gestures in anger or frustration
drink: drinks something
check_phone: looks at their phone or holo
stretch: stretches
cry: tears up, weeps
smile: smiles, smirks, grins
frown: frowns, scowls
sigh: sighs
nod: nods
shake_head: shakes their head
raise_eyebrow: raises an eyebrow
say_nothing: goes quiet, says nothing"""

IDS = [l.split(":")[0] for l in MENU.splitlines()] + ["none"]
GRAMMAR = "root ::= " + " | ".join(f'"{i}"' for i in IDS)
SYS = ("Name the one thing this line of stage direction from a roleplay game shows the "
       "character doing.\n\nOptions:\n" + MENU +
       "\n\nAnswer 'none' only if it truly matches nothing. Answer with the option id "
       "alone. One word, nothing else.")

# (beat, wanted, acceptable_alternatives)
CASES = [
 # game actions
 ("starts following V","follow",[]), ("follows close behind","follow",[]),
 ("goes with V","follow",[]), ("trails after V","follow",[]), ("keeps pace with V","follow",[]),
 ("stays put","stay_here",[]), ("stops and waits","stay_here",[]),
 ("waits by the door","stay_here",[]), ("doesn't move","stay_here",["say_nothing"]),
 ("walks away","leave",[]), ("departs","leave",[]), ("storms out","leave",["angry_gesture"]),
 ("heads for the door","leave",[]),
 ("runs off","run",[]), ("takes off running","run",[]), ("bolts","run",[]),
 ("takes a step back","step_back",[]), ("backs up","step_back",[]), ("backs away slowly","step_back",[]),
 ("steps closer","step_closer",[]), ("closes the distance","step_closer",[]),
 ("moves in close","step_closer",["lean"]),
 ("drops the gun","drop_item",[]), ("sets the pistol down","drop_item",[]),
 ("puts the bottle down","drop_item",[]),
 ("holsters her pistol","holster",[]), ("puts her gun away","holster",[]),
 ("slides the gun back into its holster","holster",[]),
 ("hands her gun to V","hand_over_weapon",[]), ("hands over the pistol","hand_over_weapon",[]),
 ("gives V the gun","hand_over_weapon",[]), ("surrenders her weapon","hand_over_weapon",[]),
 ("holds out the gun for V to take","hand_over_weapon",[]),
 ("opens fire","attack",[]), ("aims and fires","attack",[]), ("pulls the trigger","attack",[]),
 ("charges at the man with a knife","attack",[]),   # homonym trap, in context
 ("lunges at him","attack",[]), ("shoots the guy","attack",[]),
 ("hands V a stack of eddies","tip",[]), ("slips V some cash","tip",[]),
 ("counts out eddies and gives them to V","tip",[]),
 ("holds out a hand for the money","charge_money",[]),   # previous miss
 ("names her price and waits","charge_money",[]),        # previous miss
 ("demands payment","charge_money",[]), ("asks for five hundred up front","charge_money",[]),
 # gestures -> animation search
 ("cracks up laughing","laugh",[]), ("chuckles","laugh",["smile"]),
 ("shrugs","shrug",[]), ("gives a small shrug","shrug",[]),
 ("leans against the wall","lean",[]), ("leans back against the truck","lean",[]),
 ("crosses her arms","cross_arms",[]), ("folds her arms","cross_arms",[]),
 ("points at the corpo","point",[]), ("jabs a finger at him","point",["angry_gesture"]),
 ("lights a cigarette","light_cigarette",[]), ("sparks up a smoke","light_cigarette",[]),
 ("waves","wave",[]), ("gives a lazy wave","wave",[]),
 ("pauses, thinking","think",["say_nothing"]), ("mulls it over","think",["say_nothing"]),
 ("sways to the music","dance",[]), ("dances a little","dance",[]),
 ("drops into the chair","sit",[]), ("sits down on the crate","sit",[]),
 ("throws her hands up in frustration","angry_gesture",[]),
 ("clenches her fists","angry_gesture",[]),
 ("takes a swig of her beer","drink",[]), ("knocks back her drink","drink",[]),
 ("checks her holo","check_phone",[]), ("glances at her phone","check_phone",[]),
 ("stretches","stretch",[]), ("rolls her shoulders","stretch",["shrug"]),
 ("wipes away a tear","cry",[]), ("starts to tear up","cry",[]),
 # facial / no-op flavour (the railroad fix)
 ("smiles faintly","smile",[]),        # the miss that started this
 ("gives a half-smile","smile",[]), ("smirks","smile",[]),
 ("frowns","frown",[]), ("scowls","frown",["angry_gesture"]),
 ("sighs","sigh",[]), ("lets out a long sigh","sigh",[]),
 ("nods","nod",[]), ("nods slowly","nod",[]),
 ("shakes her head","shake_head",[]), ("shakes her head slowly","shake_head",[]),
 ("raises an eyebrow","raise_eyebrow",[]), ("arches a brow","raise_eyebrow",[]),
 ("says nothing for a moment","say_nothing",[]), ("goes quiet","say_nothing",[]),
 # true none
 ("looks V over","none",["raise_eyebrow","say_nothing"]),
 ("her voice drops low","none",["say_nothing"]),
 ("studies V's face","none",["say_nothing","think"]),
]

def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]

if __name__ == "__main__":
    t0=time.time(); strict=lenient=0; times=[]; misses=[]
    cats = {}
    for beat, want, alt in CASES:
        t=time.time()
        got = post({"model":"dpe","temperature":0.0,"max_tokens":12,"grammar":GRAMMAR,
            "messages":[{"role":"system","content":SYS},{"role":"user","content":beat}]}).strip().lower()
        times.append(time.time()-t)
        ok = got==want; okish = ok or got in alt
        strict+=ok; lenient+=okish
        grp = "action" if want in ("follow","stay_here","leave","run","step_back","step_closer",
              "drop_item","holster","hand_over_weapon","attack","tip","charge_money") else \
              ("flavour" if want in ("smile","frown","sigh","nod","shake_head","raise_eyebrow","say_nothing","none") else "gesture")
        s,l,n = cats.get(grp,(0,0,0)); cats[grp]=(s+ok,l+okish,n+1)
        if not okish: misses.append((beat,want,got))
    n=len(CASES)
    print(f"MERGED MENU (34 ids + none)  n={n}")
    print(f"  strict {strict}/{n} ({100*strict/n:.1f}%)   lenient {lenient}/{n} ({100*lenient/n:.1f}%)")
    print(f"  median {sorted(times)[n//2]*1000:.0f} ms")
    for g,(s,l,c) in sorted(cats.items()):
        print(f"  {g:8s} strict {s}/{c}  lenient {l}/{c}")
    print("\nmisses:")
    for b,w,g in misses: print(f"  {b!r} -> wanted {w}, got {g}")
    print(f"\n{time.time()-t0:.0f}s")
