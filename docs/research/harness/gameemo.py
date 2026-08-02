#!/usr/bin/env python3
"""Emotion classification against the GAME's own 9 facial emotions
(reactionComponent.SelectFacialEmotion). Not an invented taxonomy - these are
the only faces the engine can render, so this is an objective label set.

Two pairs render as the SAME face and are scored interchangeably:
  funny  == joy       (category 3, idle 5)
  shock  == surprise  (category 3, idle 8)
Everything else is distinct. neutral is the game's default (category 2, idle 2).
"""
import json, urllib.request
from math import sqrt
URL = "http://127.0.0.1:8081/v1/chat/completions"

# the game's 9 + neutral default, described in plain words
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

# faces that render identically -> interchangeable in scoring
SAME = {"funny": "funny_joy", "joy": "funny_joy", "shock": "shock_surprise",
        "surprise": "shock_surprise"}
def canon(x): return SAME.get(x, x)

# beats labelled ONLY where the game has a matching face. Anger examples are the
# five that failed as body-gestures; the point is whether they all read as anger.
CASES = [
 # anger (the one-to-many failure case)
 ("throws her hands up in anger","aggressive"),("clenches her fists","aggressive"),
 ("slams her fist on the table","aggressive"),("punches the wall","aggressive"),
 ("balls her hands into fists","aggressive"),("snarls at V","aggressive"),
 ("glares furiously","aggressive"),("her face twists in rage","aggressive"),
 # sad
 ("her shoulders slump","sad"),("hangs her head","sad"),
 ("stares at the floor, deflated","sad"),("looks crushed","sad"),
 ("tears well up","sad"),("her voice cracks with grief","sad"),
 # fear
 ("flinches back, terrified","fear"),("shrinks away, frightened","fear"),
 ("eyes wide with fear","fear"),("recoils in dread","fear"),
 ("freezes, afraid to move","fear"),
 # joy / funny (same face)
 ("smiles warmly","joy"),("grins with delight","joy"),
 ("her face lights up","joy"),("bursts out laughing","funny"),
 ("stifles a giggle","funny"),("snorts, amused","funny"),
 # disgust
 ("wrinkles her nose in disgust","disgust"),("sneers with contempt","disgust"),
 ("recoils, revolted","disgust"),("looks at V like something on her shoe","disgust"),
 # shock / surprise (same face)
 ("her jaw drops","shock"),("stares, stunned","shock"),
 ("startles, caught off guard","surprise"),("blinks in surprise","surprise"),
 ("eyebrows shoot up","surprise"),
 # curiosity
 ("tilts her head, curious","curiosity"),("leans in, intrigued","curiosity"),
 ("studies V with interest","curiosity"),
 # neutral / no strong emotion
 ("her expression stays flat","neutral"),("shrugs, indifferent","neutral"),
 ("meets V's eyes evenly","neutral"),("says it plainly","neutral"),
]

def wilson(k, n, z=1.96):
    p = k/n; d = 1+z*z/n
    c = p+z*z/(2*n); h = z*sqrt(p*(1-p)/n+z*z/(4*n*n))
    return (c-h)/d, (c+h)/d
def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type":"application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"].strip().lower()

ok=0; miss=[]
for beat, want in CASES:
    got = post({"model":"m","temperature":0.0,"max_tokens":8,"grammar":G,
        "messages":[{"role":"system","content":SYS},{"role":"user","content":beat}]})
    if canon(got)==canon(want): ok+=1
    else: miss.append((beat,want,got))
n=len(CASES); lo,hi=wilson(ok,n)
print(f"GAME'S 9 EMOTIONS: {ok}/{n} = {100*ok/n:.1f}%   95% CI [{100*lo:.1f}, {100*hi:.1f}]")
print("(funny==joy and shock==surprise scored as one face each)")
for b,w,g in miss: print(f"  {b!r} -> wanted {w}, got {g}")
