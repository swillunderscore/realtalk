import json, re, time, urllib.request
URL = "http://127.0.0.1:8081/v1/chat/completions"
CARD = ("Panam Palmer is an Aldecaldo nomad - hot-headed, loyal, blunt when angry. "
        "She is talking with V, a mercenary. They know each other well. "
        "Talk like a real person on a street: short, plain, sometimes blunt. "
        'Reply as Panam Palmer: one or two sentences of speech in double quotes, then a few '
        'plain words for what they physically do, or *the action between asterisks* - either '
        'way, always something. The shape is: "<what they say>" *<what they do>*'
        " Never speak or act for V - only write what they themselves say and do.")
STATE = "V is crouched behind cover with a rifle raised, aiming at a man across the lot."
PROBES = ["hey", "whats up", "you good?", "hey panam", "so...", "you see that?",
          "what do you think", "talk to me"]
NOTICE = re.compile(r"\b(gun|rifle|pistol|weapon|aim|aiming|shoot|shot|cover|crouch|"
                    r"crouched|barrel|trigger|target|firing|scope)\b", re.I)

def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]

def run(mode, rounds=4):
    notice = quoted = beat = n = 0
    shown = 0
    for probe in PROBES * rounds:
        card = CARD
        content = probe
        if mode == "system":
            card = CARD + f" Right now, {STATE}"
        elif mode == "beat":
            content = f"{probe} *crouched behind cover, rifle raised at a man across the lot*"
        reply = re.sub(r"\s+", " ", post({"model": "dpe", "temperature": 0.7, "max_tokens": 100,
            "messages": [{"role": "system", "content": card},
                         {"role": "user", "content": content}]})).strip()
        n += 1
        quoted += '"' in reply
        b = re.sub(r'"[^"]*"', " ", reply).replace("*", " ") if '"' in reply \
            else " ".join(re.findall(r"\*([^*]+)\*", reply))
        beat += len(re.sub(r"\s+", " ", b).strip()) > 2
        if NOTICE.search(reply):
            notice += 1
            if shown < 2:
                shown += 1
                print(f"      {reply[:105]}", flush=True)
    label = {"none": "no state given ", "system": "state in card  ",
             "beat": "state as a beat"}[mode]
    print(f"{label} noticed-the-situation {notice:2d}/{n}  quotes {100*quoted//n:3d}%  "
          f"beat {100*beat//n:3d}%", flush=True)

if __name__ == "__main__":
    t0 = time.time()
    for m in ("none", "system", "beat"):
        run(m)
    print(f"\n{time.time()-t0:.0f}s")
