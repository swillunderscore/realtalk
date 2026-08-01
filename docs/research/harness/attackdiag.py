import json, re, urllib.request
URL = "http://127.0.0.1:8081/v1/chat/completions"
BASE = ("Panam Palmer is an Aldecaldo nomad, blunt and loyal, talking with V, a mercenary. "
        "Right now she trusts V completely and goes along with whatever V asks, without "
        "arguing. Talk like a real person: short, plain, sometimes blunt. "
        'Reply as Panam Palmer: one or two sentences of speech in double quotes, then a few '
        'plain words for what they physically do, or *the action between asterisks*. '
        'The shape is: "<what they say>" *<what they do>*')
ACTS = """follow: goes with V
stay_here: stops following, waits
leave: walks off
run: flees
step_back: backs off
step_closer: comes nearer to V
drop_item: puts down what they are holding
attack: opens fire, shoots, stabs or charges at someone, starts a fight
tip: hands eddies to V
bill: asks V for eddies, names a price"""
IDS = [l.split(":")[0] for l in ACTS.splitlines()] + ["none"]
G = "root ::= " + " | ".join(f'"{i}"' for i in IDS)
AGREED = ("A game character has just replied to the player. Name the one action they are now "
          "doing, or have just agreed to do.\n\nActions:\n" + ACTS +
          "\n\nAnswer 'none' if they only talked or refused. One word.")
BEATONLY = ("Name the one action this line of stage direction describes.\n\nActions:\n" + ACTS +
            "\n\nAnswer 'none' if it matches nothing. One word.")

def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"].strip()

for line in ["shoot him", "kill that guy", "take the shot", "ya go for it kill him",
             "im ready, shoot", "light him up"]:
    reply = post({"model":"dpe","temperature":0.7,"max_tokens":100,
                  "messages":[{"role":"system","content":BASE},{"role":"user","content":line}]})
    reply = re.sub(r"\s+", " ", reply).strip()
    beat = re.sub(r'"[^"]*"', " ", reply).replace("*"," ").strip() if '"' in reply \
           else " ".join(re.findall(r"\*([^*]+)\*", reply))
    beat = re.sub(r"\s+", " ", beat).strip()
    full = post({"model":"dpe","temperature":0.0,"max_tokens":12,"grammar":G,
                 "messages":[{"role":"system","content":AGREED},{"role":"user","content":reply}]}).lower()
    just = post({"model":"dpe","temperature":0.0,"max_tokens":12,"grammar":G,
                 "messages":[{"role":"system","content":BEATONLY},{"role":"user","content":beat}]}).lower() if beat else "-"
    print(f"{line:22s} full={full:10s} beat-only={just:10s}")
    print(f"    reply: {reply[:110]}")
    print(f"    beat : {beat[:90]}")
