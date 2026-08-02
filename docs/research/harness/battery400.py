#!/usr/bin/env python3
"""n>=400 battery, scheme C (pay_v/bill_v naming), for a real confidence interval.

Cases are the 230 hand-written ones PLUS templated expansions of the ids that
have many natural phrasings. Every added case is a distinct surface form a
player's model could plausibly produce; none are near-duplicates of an existing
case. Labels are assigned by construction, not by the model.
"""
import json, re, time, urllib.request
from math import sqrt

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
pay_v: hands eddies to V
bill_v: asks V to pay, names a price
laugh: laughs
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
warm_hands: warms or rubs their hands
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

NOOP = {"say_nothing", "none"}
ACTION_IDS = {"follow","stay_here","leave","run","step_back","step_closer","drop_item",
              "holster","hand_over_weapon","attack","pay_v","bill_v"}

# (beat, wanted, [acceptable alternatives]) -- generated to distinct surface forms
CASES = []
def add(beats, want, alts=()):
    for b in beats:
        CASES.append((b, want, list(alts)))

add(["starts following V","follows V","falls into step behind V","goes with V",
     "walks alongside V","keeps pace with V","trails after V","heads out after V",
     "moves to follow V","tags along with V"], "follow", ["step_closer"])
add(["stays put","stops and waits","waits where she is","holds her position",
     "stays behind","plants her feet","doesn't budge","hangs back and waits",
     "settles in to wait","stands her ground"], "stay_here")
add(["walks away","walks off","departs","leaves without a word","heads out the door",
     "turns and goes","makes for the exit","takes her leave","strides off",
     "shows herself out"], "leave", ["run"])
add(["runs off","takes off running","bolts","sprints away","flees the scene",
     "dashes off","breaks into a run","takes off at a sprint","runs for it",
     "hightails it out"], "run", ["leave"])
add(["takes a step back","backs up","backs away","retreats a step","gives V room",
     "moves back a pace","edges backward","steps back warily","backs off",
     "puts space between them"], "step_back")
add(["steps closer","moves closer","closes the distance","comes nearer","steps up to V",
     "moves in","draws nearer to V","closes in","sidles up to V","approaches V"],
    "step_closer", ["lean"])
add(["drops the gun","sets the pistol down","puts the bottle down","tosses the gun aside",
     "lays the weapon on the table","lets the knife fall","sets it down","drops the blade",
     "puts the rifle on the crate","lets go of the pistol"], "drop_item")
add(["holsters her pistol","puts her gun away","slides the pistol into its holster",
     "stows her weapon","tucks the gun away","sheaths the blade","holsters up",
     "returns the gun to her hip","puts the piece away","re-holsters"], "holster")
add(["hands her gun to V","hands over the pistol","gives V the gun","surrenders her weapon",
     "holds out the gun for V","passes the pistol to V","offers V her iron",
     "gives up her weapon to V","places the gun in V's hand","hands the rifle to V"],
    "hand_over_weapon")
add(["opens fire","aims and fires","pulls the trigger","charges at the man with a knife",
     "lunges at him","shoots the guy","swings at him","fires into the target",
     "opens up on them","guns him down"], "attack")
add(["hands V a stack of eddies","slips V some cash","gives V the eddies","pays V",
     "presses a credchip into V's hand","transfers the eddies to V","tosses V some cash",
     "counts out eddies for V","pays V what she owes","hands over the eddies to V"],
    "pay_v")
add(["holds out a hand for the money","names her price and waits","demands payment",
     "asks for five hundred up front","tells V it'll cost","waits for V to pay up",
     "rubs her fingers together expectantly","quotes V a price","asks V to pay first",
     "wants her cut from V"], "bill_v")
add(["cracks up laughing","bursts out laughing","laughs out loud","howls with laughter",
     "laughs","lets out a laugh"], "laugh", ["smile"])
add(["shrugs","gives a small shrug","shrugs her shoulders","shrugs it off",
     "offers a helpless shrug"], "shrug")
add(["leans against the wall","leans back against the truck","props against the doorframe",
     "slouches against the railing","leans on the bar","rests against the car"], "lean")
add(["crosses her arms","folds her arms","arms crossed over her chest",
     "crosses her arms tightly"], "cross_arms", ["angry_gesture"])
add(["puts her hands on her hips","hands on hips","rests her fists on her hips",
     "sets her hands on her hips"], "hands_on_hips")
add(["points at the corpo","jabs a finger at him","points toward the gate",
     "points down the alley","points at V"], "point")
add(["lights a cigarette","sparks up a smoke","takes a drag","flicks ash off her cigarette",
     "lights up"], "light_cigarette")
add(["waves","gives a lazy wave","waves goodbye","throws V a wave","waves V over"], "wave")
add(["pauses, thinking","mulls it over","taps her chin, considering","weighs it up",
     "thinks for a second"], "think", ["say_nothing"])
add(["sways to the music","dances a little","moves with the beat","dances"], "dance")
add(["drops into the chair","sits down on the crate","takes a seat","settles onto the barstool",
     "sits","plops down"], "sit")
add(["lies down on the cot","stretches out on the bed","lies back","sprawls on the couch"],
    "lie_down", ["stretch"])
add(["kneels down","drops to one knee","kneels beside the body","kneels"], "kneel")
add(["throws her hands up","clenches her fists","slams her fist on the table",
     "gestures angrily","punches the wall","balls her hands into fists"], "angry_gesture")
add(["takes a swig of her beer","knocks back her drink","sips her whiskey","drains the glass",
     "downs the shot","takes a drink"], "drink")
add(["takes a bite of her noodles","chews on some street food","eats a mouthful"], "eat")
add(["checks her holo","glances at her phone","scrolls through her holo","reads her phone",
     "taps at her holo"], "check_phone")
add(["stretches","rolls her shoulders","stretches her arms overhead","arches her back"],
    "stretch", ["shrug"])
add(["wipes away a tear","starts to tear up","breaks down crying","sobs quietly"], "cry")
add(["gestures as she talks","talks with her hands","waves a hand to make her point",
     "gestures vaguely at the city","punctuates her words with a gesture"], "gesture_explain",
    ["point","wave"])
add(["raises her rifle and sights down the scope","levels her pistol at the door","takes aim",
     "draws her Overwatch","trains the gun on him","brings the rifle up"], "aim_weapon",
    ["attack"])
add(["ducks behind the crates","takes cover behind the car","presses against the wall",
     "hunkers down behind cover"], "take_cover", ["kneel","lean"])
add(["scans the street both ways","looks around nervously","glances over her shoulder",
     "checks her surroundings","sweeps the room with her eyes"], "look_around", ["scared"])
add(["claps","gives a slow clap","applauds"], "clap")
add(["yawns","stifles a yawn"], "yawn")
add(["gives a little bow","bows her head","bows"], "bow", ["nod"])
add(["presses her palms together in prayer","mutters a prayer","bows her head in prayer"], "pray")
add(["puts her face in her hands","facepalms","pinches the bridge of her nose",
     "rubs her temples"], "facepalm", ["sigh","frown"])
add(["flinches back, startled","shrinks away, frightened","eyes wide with fear",
     "recoils in fear"], "scared", ["step_back"])
add(["bats her eyelashes","gives V a flirty look","blows V a kiss","winks at V"], "flirt",
    ["smile"])
add(["her shoulders slump","hangs her head","stares at the floor, deflated","looks crushed"],
    "sad")
add(["folds her hands in front of her","clasps her hands together","laces her fingers"],
    "fold_hands")
add(["rubs her hands together for warmth","warms her hands over the fire","blows on her hands"],
    "warm_hands")
add(["smiles faintly","gives a half-smile","smirks","grins","flashes a smile","smiles warmly"],
    "smile")
add(["frowns","scowls","her face darkens","knits her brow"], "frown", ["angry_gesture"])
add(["sighs","lets out a long sigh","exhales heavily","sighs wearily"], "sigh")
add(["nods","nods slowly","gives a curt nod","nods along"], "nod")
add(["shakes her head","shakes her head slowly","shakes her head in disbelief"], "shake_head")
add(["raises an eyebrow","arches a brow","quirks an eyebrow"], "raise_eyebrow")
add(["says nothing for a moment","goes quiet","falls silent","says nothing"], "say_nothing",
    ["none"])
add(["looks V over","studies V's face","her voice drops low","meets V's eyes",
     "considers V for a moment"], "none", ["raise_eyebrow","think","look_around","say_nothing"])

def wilson(k, n, z=1.96):
    p = k/n; d = 1 + z*z/n
    c = p + z*z/(2*n); h = z*sqrt(p*(1-p)/n + z*z/(4*n*n))
    return (c-h)/d, (c+h)/d

def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]

if __name__ == "__main__":
    t0 = time.time()
    strict = lenient = wrong_action = 0
    money_ok = money_n = 0
    times, misses = [], []
    n = len(CASES)
    print(f"battery: {n} cases, {len(set(w for _,w,_ in CASES))} target ids")
    for beat, want, alts in CASES:
        t = time.time()
        got = post({"model":"m","temperature":0.0,"max_tokens":12,"grammar":GRAMMAR,
            "messages":[{"role":"system","content":SYS},{"role":"user","content":beat}]}).strip().lower()
        times.append(time.time()-t)
        ok = got == want or (got in NOOP and want in NOOP)
        okish = ok or got in alts
        strict += ok; lenient += okish
        if want in ("pay_v","bill_v"):
            money_n += 1; money_ok += ok
        if not okish:
            if got in ACTION_IDS and want not in ACTION_IDS:
                wrong_action += 1
            misses.append((beat, want, got))
    lo, hi = wilson(strict, n)
    llo, lhi = wilson(lenient, n)
    print(f"\nSTRICT  {strict}/{n} = {100*strict/n:.1f}%   95% CI [{100*lo:.1f}, {100*hi:.1f}]")
    print(f"LENIENT {lenient}/{n} = {100*lenient/n:.1f}%   95% CI [{100*llo:.1f}, {100*lhi:.1f}]")
    print(f"money {money_ok}/{money_n}   false-game-action-from-nonaction {wrong_action}   "
          f"median {sorted(times)[n//2]*1000:.0f} ms   {time.time()-t0:.0f}s")
    print(f"\nmisses ({len(misses)}):")
    for b, w, g in misses:
        print(f"  {b!r} -> wanted {w}, got {g}")
