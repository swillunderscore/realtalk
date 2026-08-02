#!/usr/bin/env python3
"""Hypothesis: emotions fail as body-gesture ids because one emotion has many
physical forms. Fix: classify the EMOTION, route it to the facial system.
Same beats that scored 60% as gestures, now against an emotion menu."""
import json, urllib.request
URL="http://127.0.0.1:8081/v1/chat/completions"
MENU="""angry: anger, rage, frustration, fury
sad: sadness, grief, dejection, despair
afraid: fear, fright, alarm, dread
happy: happiness, joy, warmth, amusement
disgusted: disgust, contempt, revulsion
surprised: surprise, shock, astonishment
flirty: flirtation, seduction, playful desire
neutral: no strong emotion"""
IDS=[l.split(":")[0] for l in MENU.splitlines()]
G="root ::= "+" | ".join(f'"{i}"' for i in IDS)
SYS=("Name the emotion this line of stage direction from a roleplay game shows.\n\n"
     "Emotions:\n"+MENU+"\n\nAnswer with the emotion id alone. One word.")
# the exact emotion beats that missed as gestures, plus their siblings
CASES=[
 ("throws her hands up","angry"),("clenches her fists","angry"),
 ("slams her fist on the table","angry"),("punches the wall","angry"),
 ("balls her hands into fists","angry"),("gestures angrily","angry"),
 ("her shoulders slump","sad"),("hangs her head","sad"),
 ("stares at the floor, deflated","sad"),("looks crushed","sad"),
 ("flinches back, startled","afraid"),("shrinks away, frightened","afraid"),
 ("eyes wide with fear","afraid"),("recoils in fear","afraid"),
 ("puts her face in her hands","sad"),("pinches the bridge of her nose","angry"),
 ("rubs her temples","angry"),("her face darkens","angry"),
 ("knits her brow","angry"),("smiles warmly","happy"),
 ("grins","happy"),("bats her eyelashes","flirty"),
 ("winks at V","flirty"),("blows V a kiss","flirty"),
 ("scowls","angry"),("frowns","angry"),
 ("bursts out laughing","happy"),("her voice drops low","neutral"),
 ("studies V's face","neutral"),("meets V's eyes","neutral"),
]
def post(p):
 r=urllib.request.urlopen(urllib.request.Request(URL,json.dumps(p).encode(),
   {"Content-Type":"application/json"}),timeout=200)
 return json.load(r)["choices"][0]["message"]["content"].strip().lower()
ok=0; miss=[]
for beat,want in CASES:
 got=post({"model":"m","temperature":0.0,"max_tokens":8,"grammar":G,
   "messages":[{"role":"system","content":SYS},{"role":"user","content":beat}]})
 if got==want: ok+=1
 else: miss.append((beat,want,got))
print(f"EMOTION MENU: {ok}/{len(CASES)} = {100*ok/len(CASES):.0f}%  (was 60% as gestures)")
for b,w,g in miss: print(f"  {b!r} -> wanted {w}, got {g}")
