import json, urllib.request
URL = "http://127.0.0.1:8081/v1/chat/completions"
BEATS = [ ("I punch him.", "attack"), ("I pull out my pistol and aim at the target", "attack"),
          ("levels the rifle and fires", "attack"), ("charges at the guy with a knife", "attack"),
          ("rushes him", "attack"), ("draws down on the corpo", "attack"),
          ("names her price and waits", "bill"), ("holds out a hand for the money", "bill"),
          ("asks for five hundred up front", "bill"), ("she wants paying first", "bill") ]
BASE = """follow: goes with V
stay_here: stops following, waits, holds position
leave: walks off, ends the conversation
run: flees, runs away
step_back: backs off, gives V space
step_closer: comes nearer to V
drop_item: puts down or drops what they are holding
attack: opens fire on someone, starts a fight
tip: hands eddies to V
"""
def go(idname, label):
    actions = BASE + f"{idname}: asks V for eddies, names a price"
    ids = [l.split(":")[0] for l in actions.splitlines() if l.strip()] + ["none"]
    g = "root ::= " + " | ".join(f'"{i}"' for i in ids)
    sysmsg = ("Name the one action this line of stage direction describes.\n\nActions:\n"
              + actions + "\n\nAnswer 'none' if it matches nothing. One word only.")
    ok = 0
    for beat, want in BEATS:
        want = idname if want == "bill" else want
        body = json.dumps({"model":"dpe","temperature":0.0,"max_tokens":12,"grammar":g,
            "messages":[{"role":"system","content":sysmsg},{"role":"user","content":beat}]}).encode()
        r = urllib.request.urlopen(urllib.request.Request(URL, body, {"Content-Type":"application/json"}), timeout=120)
        got = json.load(r)["choices"][0]["message"]["content"].strip().lower()
        mark = "ok  " if got == want else "MISS"
        if got == want: ok += 1
        else: print(f"    {mark} {beat[:44]:44s} -> {got:10s} (want {want})")
    print(f"  id '{idname}': {ok}/{len(BEATS)}")
print("=== the money action named 'charge' (a homonym) ===")
go("charge", "charge")
print("=== the same action named 'bill' ===")
go("bill", "bill")
