#!/usr/bin/env python3
"""Full-scale emotion battery vs the GAME's 9 facial emotions - comparable
rigor to the 297-case action battery. Label set = reactionComponent
.SelectFacialEmotion (objective, engine-defined). funny==joy and shock==surprise
render identically and are scored as one face each. Genuinely ambiguous beats
carry acceptable alternatives."""
import json, urllib.request
from math import sqrt
URL = "http://127.0.0.1:8081/v1/chat/completions"
MENU = """aggressive: anger, rage, fury, hostility, aggression
curiosity: curiosity, interest, intrigue
disgust: disgust, contempt, revulsion, distaste
fear: fear, fright, dread, alarm, terror
funny: amusement, finding something funny
joy: joy, happiness, delight, warmth
sad: sadness, grief, sorrow, dejection
shock: shock, being stunned
surprise: surprise, being startled, astonishment
neutral: no strong emotion"""
IDS = [l.split(":")[0] for l in MENU.splitlines()]
G = "root ::= " + " | ".join(f'"{i}"' for i in IDS)
SYS = ("Name the single emotion this line of stage direction from a game shows the "
       "character feeling.\n\nEmotions:\n" + MENU +
       "\n\nAnswer 'neutral' if there is no strong emotion. Answer with the emotion id "
       "alone. One word.")
SAME = {"funny":"J","joy":"J","shock":"S","surprise":"S"}
def canon(x): return SAME.get(x, x)

CASES=[]
def add(beats, want, alts=()):
    for b in beats: CASES.append((b, want, list(alts)))

add(["throws her hands up in anger","clenches her fists","slams her fist on the table",
 "punches the wall","balls her hands into fists","snarls at V","glares furiously",
 "her face twists in rage","bares her teeth","kicks a chair across the room",
 "grits her teeth","her eyes flash with fury","spits on the ground, seething",
 "jabs a finger in V's chest, furious","shouts, red in the face","slams the door",
 "her knuckles whiten on the grip","growls low in her throat","seethes",
 "storms toward V, fists up"], "aggressive", ["neutral"])
add(["her shoulders slump","hangs her head","stares at the floor, deflated",
 "looks crushed","tears well up","her voice cracks with grief","wipes her eyes",
 "sniffles quietly","her lip trembles","sighs, heartbroken","slumps against the wall, defeated",
 "buries her face in her hands","chokes back a sob","looks away, eyes wet",
 "her whole body sags","stares into the distance, mournful","whispers, voice breaking",
 "goes quiet, grief-stricken"], "sad", ["neutral"])
add(["flinches back, terrified","shrinks away, frightened","eyes wide with fear",
 "recoils in dread","freezes, afraid to move","backs away, trembling",
 "her breath catches in fear","goes pale","cowers","raises her hands defensively, scared",
 "her voice shakes with fright","glances around, panicked","presses herself to the wall in terror",
 "whimpers"], "fear", ["neutral","surprise"])
add(["smiles warmly","grins with delight","her face lights up","beams at V",
 "laughs happily","her eyes sparkle with joy","hums contentedly","smiles softly",
 "practically glows","gives V a warm hug"], "joy", ["funny"])
add(["bursts out laughing","stifles a giggle","snorts, amused","cracks up",
 "chuckles at the joke","grins, trying not to laugh","laughs so hard she wheezes",
 "smirks, amused"], "funny", ["joy"])
add(["wrinkles her nose in disgust","sneers with contempt","recoils, revolted",
 "looks at V like something on her shoe","curls her lip in distaste","gags",
 "scoffs, disgusted","turns away, repulsed","shudders with revulsion",
 "eyes V with contempt"], "disgust", ["aggressive"])
add(["her jaw drops","stares, stunned","reels back, shocked","freezes, dumbstruck",
 "her eyes go wide with shock","gapes","can't believe what she's hearing"], "shock", ["surprise"])
add(["startles, caught off guard","blinks in surprise","eyebrows shoot up",
 "gasps, surprised","does a double take","jumps, startled","her head snaps around, surprised",
 "hadn't expected that"], "surprise", ["shock"])
add(["tilts her head, curious","leans in, intrigued","studies V with interest",
 "raises an eyebrow, curious","looks V over, wondering","her eyes narrow with interest",
 "asks, genuinely curious","cocks her head, wondering"], "curiosity", ["neutral"])
add(["her expression stays flat","shrugs, indifferent","meets V's eyes evenly",
 "says it plainly","her face gives nothing away","looks at V, unreadable",
 "stays calm","nods, matter-of-fact","keeps a straight face","answers flatly"], "neutral")

def wilson(k,n,z=1.96):
    p=k/n; d=1+z*z/n; c=p+z*z/(2*n); h=z*sqrt(p*(1-p)/n+z*z/(4*n*n))
    return (c-h)/d,(c+h)/d
def post(p):
    r=urllib.request.urlopen(urllib.request.Request(URL,json.dumps(p).encode(),
      {"Content-Type":"application/json"}),timeout=200)
    return json.load(r)["choices"][0]["message"]["content"].strip().lower()

strict=lenient=0; miss=[]
n=len(CASES)
for beat,want,alts in CASES:
    got=post({"model":"m","temperature":0.0,"max_tokens":8,"grammar":G,
        "messages":[{"role":"system","content":SYS},{"role":"user","content":beat}]})
    ok = canon(got)==canon(want)
    okish = ok or canon(got) in [canon(a) for a in alts]
    strict+=ok; lenient+=okish
    if not okish: miss.append((beat,want,got))
lo,hi=wilson(strict,n); llo,lhi=wilson(lenient,n)
print(f"EMOTION BATTERY vs GAME'S 9   n={n}")
print(f"  STRICT  {strict}/{n} = {100*strict/n:.1f}%   95% CI [{100*lo:.1f}, {100*hi:.1f}]")
print(f"  LENIENT {lenient}/{n} = {100*lenient/n:.1f}%   95% CI [{100*llo:.1f}, {100*lhi:.1f}]")
print(f"  (funny==joy, shock==surprise scored as one face each)")
print(f"\nmisses ({len(miss)}):")
for b,w,g in miss: print(f"  {b!r} -> wanted {w}, got {g}")
