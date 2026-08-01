#!/usr/bin/env python3
"""The full-scale battery: 53-id merged menu, ~350 labelled cases, and a
three-way A/B on the money-action naming (the one persistent error class).

Menu = 12 game actions + 33 gesture categories (every one verified to have
animation coverage in the AMM workspot db, Woman Average rig) + 7 facial/no-op
ids + none. say_nothing and none are scored as interchangeable (both no-op).
"""
import json, re, time, urllib.request
from math import sqrt

URL = "http://127.0.0.1:8081/v1/chat/completions"

ACTIONS_BASE = """follow: goes with V, walks with V
stay_here: stops following, waits, holds position
leave: walks off, ends the conversation
run: flees, runs away
step_back: backs off, gives V space
step_closer: comes nearer to V
drop_item: puts down or drops what they are holding
holster: puts their weapon away
hand_over_weapon: gives their weapon to V
attack: opens fire, stabs, lunges, starts a fight"""

MONEY = {
 "A_current": ("tip: hands eddies to V",
               "charge_money: asks V for payment"),
 "B_directional_desc": ("tip: gives their OWN eddies to V",
               "charge_money: wants eddies FROM V, names a price, waits to be paid"),
 "C_renamed": ("pay_v: hands eddies to V",
               "bill_v: asks V to pay, names a price"),
}
MONEY_MAP = {"pay_v": "tip", "bill_v": "charge_money"}  # normalise C for scoring

GESTURES = """laugh: laughs
shrug: shrugs
lean: leans on something
cross_arms: folds their arms
hands_on_hips: puts hands on hips
point: points at something or someone
light_cigarette: lights or smokes a cigarette
wave: waves
think: pauses to think
dance: dances, sways to music
sit: sits down
lie_down: lies down
kneel: kneels
angry_gesture: gestures in anger or frustration
drink: drinks something
eat: eats something
check_phone: looks at their phone or holo
stretch: stretches
cry: tears up, weeps
gesture_explain: gestures while talking, talks with their hands
aim_weapon: raises or aims a weapon without firing
take_cover: ducks or takes cover
look_around: scans their surroundings
clap: claps
yawn: yawns
bow: bows
pray: prays
facepalm: covers their face with a hand
scared: flinches, recoils in fear
flirt: flirts, acts seductive
sad: slumps, looks dejected
fold_hands: clasps their hands together
warm_hands: warms or rubs their hands"""

FLAVOUR = """smile: smiles, smirks, grins
frown: frowns, scowls
sigh: sighs
nod: nods
shake_head: shakes their head
raise_eyebrow: raises an eyebrow
say_nothing: goes quiet, says nothing"""

# ---------------- battery ----------------
# id -> list of beats; tuples are (beat, [acceptable alternatives])
C = {
"follow": ["starts following V","follows V","falls into step behind V","goes with V",
  "walks alongside V","keeps pace with V","trails after V","sticks close to V",
  ("follows close behind",["step_closer"]),"sets off after V"],
"stay_here": ["stays put","stops and waits","waits where she is","holds her position",
  "stays behind","plants her feet",("remains by the truck",["lean"]),"doesn't budge",
  "waits for V to come back"],
"leave": ["walks away","walks off","departs","leaves without a word","heads out",
  ("storms off",["angry_gesture","run"]),"turns and goes","makes for the exit",
  "walks out of the bar"],
"run": ["runs off","takes off running","bolts","sprints away","flees","dashes off",
  "breaks into a run",("runs for it",["leave"])],
"step_back": ["takes a step back","backs up","backs away","retreats a step",
  "gives V some room","moves back a pace",("backs away slowly",[])],
"step_closer": ["steps closer","moves closer","closes the distance","comes nearer",
  "steps up to V","moves in",("leans in close",["lean"])],
"drop_item": ["drops the gun","sets the pistol down","puts the bottle down",
  "lets the knife clatter to the floor","tosses the gun aside",
  "lays the weapon on the table",("puts it down on the bar",[])],
"holster": ["holsters her pistol","puts her gun away",
  "slides the pistol back into its holster","stows her weapon","tucks the gun away",
  "returns the blade to its sheath"],
"hand_over_weapon": ["hands her gun to V","hands over the pistol","gives V the gun",
  "surrenders her weapon","holds out the gun for V to take","passes the pistol to V",
  ("offers V her iron",[])],
"attack": ["opens fire","aims and fires","pulls the trigger",
  "charges at the man with a knife","lunges at him","shoots the guy",
  ("swings at him",[]),"fires two rounds into the target",
  ("levels the rifle at the guy and fires",[])],
"tip": ["hands V a stack of eddies","slips V some cash",
  "counts out eddies and gives them to V","pays V","transfers the eddies to V",
  "presses a credchip into V's hand",("slides a stack of eddies across the table to V",[])],
"charge_money": ["holds out a hand for the money","names her price and waits",
  "demands payment","asks for five hundred up front","tells V it'll cost extra",
  "waits for V to pay up",("rubs her fingers together expectantly",[])],
"laugh": ["cracks up laughing","bursts out laughing",("chuckles",["smile"]),
  "laughs out loud",("snorts with laughter",["smile"])],
"shrug": ["shrugs","gives a small shrug","shrugs her shoulders",
  ("shrugs it off",[])],
"lean": ["leans against the wall","leans back against the truck",
  "props herself against the doorframe",("slouches against the railing",[])],
"cross_arms": ["crosses her arms","folds her arms","arms crossed over her chest",
  ("crosses her arms and glares",["angry_gesture","frown"])],
"hands_on_hips": ["puts her hands on her hips","hands on hips",
  "rests her fists on her hips"],
"point": ["points at the corpo","jabs a finger at him","points toward the gate",
  ("points down the alley",[])],
"light_cigarette": ["lights a cigarette","sparks up a smoke","takes a drag",
  ("flicks ash off her cigarette",[])],
"wave": ["waves","gives a lazy wave","waves goodbye",("throws V a lazy wave",[])],
"think": [("pauses, thinking",["say_nothing"]),("mulls it over",["say_nothing"]),
  "taps her chin, considering",("weighs it up for a second",["say_nothing"])],
"dance": ["sways to the music","dances a little","moves with the beat"],
"sit": ["drops into the chair","sits down on the crate","takes a seat",
  "settles onto the barstool"],
"lie_down": ["lies down on the cot",("stretches out on the bed",["stretch"]),
  "lies back and stares at the ceiling"],
"kneel": ["kneels down","drops to one knee",("kneels beside the body",[])],
"angry_gesture": ["throws her hands up in frustration","clenches her fists",
  ("slams her fist on the table",[]),"gestures angrily",
  ("kicks a can across the street",[])],
"drink": ["takes a swig of her beer","knocks back her drink","sips her whiskey",
  "drains the glass"],
"eat": ["takes a bite of her noodles","chews on some street food"],
"check_phone": ["checks her holo","glances at her phone","scrolls through her holo",
  "reads something on her phone"],
"stretch": ["stretches",("rolls her shoulders",["shrug"]),
  "stretches her arms overhead"],
"cry": ["wipes away a tear","starts to tear up","breaks down crying"],
"gesture_explain": ["gestures as she talks","talks with her hands",
  "waves a hand to make her point",("gestures vaguely at the city",["point"])],
"aim_weapon": [("raises her rifle and sights down the scope",["attack"]),
  ("levels her pistol at the door",["attack"]),("takes aim",["attack"]),
  ("draws her Overwatch",["attack"])],
"take_cover": [("ducks behind the crates",["kneel"]),"takes cover behind the car",
  ("presses herself against the wall",["lean","scared"])],
"look_around": ["scans the street both ways",("looks around nervously",["scared"]),
  "glances over her shoulder","checks her surroundings"],
"clap": ["claps",("gives a slow clap",[]),"applauds"],
"yawn": ["yawns","stifles a yawn"],
"bow": ["gives a little bow",("bows her head",["nod","sad"])],
"pray": ["presses her palms together in prayer","mutters a quick prayer"],
"facepalm": ["puts her face in her hands","facepalms",
  ("pinches the bridge of her nose",["frown","sigh"])],
"scared": [("flinches back, startled",["step_back"]),
  ("shrinks away, frightened",["step_back"]),"eyes wide with fear"],
"flirt": [("bats her eyelashes",["smile"]),("gives V a flirty look",["smile"]),
  "blows V a kiss"],
"sad": [("her shoulders slump",[]),("hangs her head",["nod","cry"]),
  ("stares at the floor, deflated",[])],
"fold_hands": ["folds her hands in front of her","clasps her hands together"],
"warm_hands": ["rubs her hands together for warmth",
  "warms her hands over the barrel fire"],
"smile": ["smiles faintly","gives a half-smile","smirks","grins","flashes a smile"],
"frown": ["frowns",("scowls",["angry_gesture"]),("her face darkens",["angry_gesture"])],
"sigh": ["sighs","lets out a long sigh","exhales heavily"],
"nod": ["nods","nods slowly","gives a curt nod"],
"shake_head": ["shakes her head","shakes her head slowly"],
"raise_eyebrow": ["raises an eyebrow","arches a brow","quirks an eyebrow"],
"say_nothing": ["says nothing for a moment","goes quiet","falls silent"],
"none": [("looks V over",["raise_eyebrow","look_around"]),
  ("studies V's face",["think"]),"her voice drops low","meets V's eyes",
  ("considers V for a moment",["think"])],
}

NOOP = {"say_nothing", "none"}   # same router outcome; interchangeable in scoring
ACTION_IDS = {"follow","stay_here","leave","run","step_back","step_closer",
              "drop_item","holster","hand_over_weapon","attack","tip","charge_money"}

def wilson(k, n, z=1.96):
    p = k / n; d = 1 + z*z/n
    c = p + z*z/(2*n); h = z*sqrt(p*(1-p)/n + z*z/(4*n*n))
    return (c-h)/d, (c+h)/d

def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]

def run_scheme(name, money_lines):
    menu = ACTIONS_BASE + "\n" + "\n".join(money_lines) + "\n" + GESTURES + "\n" + FLAVOUR
    ids = [l.split(":")[0] for l in menu.splitlines()] + ["none"]
    grammar = "root ::= " + " | ".join(f'"{i}"' for i in ids)
    sysmsg = ("Name the one thing this line of stage direction from a roleplay game "
              "shows the character doing.\n\nOptions:\n" + menu +
              "\n\nAnswer 'none' only if it truly matches nothing. Answer with the "
              "option id alone. One word, nothing else.")
    strict = lenient = n = 0
    wrong_action = 0          # a game action fired that should not have
    money_ok = money_n = 0
    times, misses = [], []
    for want, beats in C.items():
        for item in beats:
            beat, alts = (item, []) if isinstance(item, str) else item
            t = time.time()
            got = post({"model":"m","temperature":0.0,"max_tokens":12,"grammar":grammar,
                "messages":[{"role":"system","content":sysmsg},
                            {"role":"user","content":beat}]}).strip().lower()
            times.append(time.time()-t); n += 1
            got_n = MONEY_MAP.get(got, got)
            ok = got_n == want or (got_n in NOOP and want in NOOP)
            okish = ok or got_n in alts
            strict += ok; lenient += okish
            if want in ("tip","charge_money"):
                money_n += 1; money_ok += ok
            if not okish:
                if got_n in ACTION_IDS and want not in ACTION_IDS:
                    wrong_action += 1
                misses.append((beat, want, got_n))
    lo, hi = wilson(strict, n)
    print(f"\n===== scheme {name} =====")
    print(f"  n={n}  strict {strict}/{n} ({100*strict/n:.1f}%)  "
          f"CI [{100*lo:.1f}, {100*hi:.1f}]  lenient {lenient}/{n} ({100*lenient/n:.1f}%)")
    print(f"  money subset {money_ok}/{money_n}  "
          f"false-game-action-from-nonaction {wrong_action}  "
          f"median {sorted(times)[n//2]*1000:.0f} ms")
    print(f"  misses ({len(misses)}):")
    for b, w, g in misses:
        print(f"    {b!r} -> wanted {w}, got {g}")

if __name__ == "__main__":
    t0 = time.time()
    total = sum(len(v) for v in C.values())
    print(f"battery: {total} cases, {len(C)} target ids")
    for name, lines in MONEY.items():
        run_scheme(name, lines)
    print(f"\ntotal {time.time()-t0:.0f}s")
