import json, re, time, urllib.request
URL = "http://127.0.0.1:8081/v1/chat/completions"
CARD = ("Panam Palmer is an Aldecaldo nomad - hot-headed, loyal, blunt when angry. "
        "She is talking with V, a mercenary. They know each other well. "
        "Talk like a real person on a street: short, plain, sometimes blunt. "
        'Reply as Panam Palmer: one or two sentences of speech in double quotes, then a few '
        'plain words for what they physically do, or *the action between asterisks* - either '
        'way, always something. The shape is: "<what they say>" *<what they do>*'
        " Never speak or act for V - only write what they themselves say and do.")
HISTORY = [("user", "hey panam you got a sec?"),
           ("assistant", '"Always. What\'s on your mind?" *leans against the truck*'),
           ("user", "was gonna ask about the job tomorrow"),
           ("assistant", '"Nothing\'s changed. In and out, no heroics." *checks her rifle*')]
STATE = "crouched behind cover, rifle raised at a man across the lot"
PROBES = ["hey", "whats up", "you good?", "shoot him", "take the shot", "follow me",
          "wait here", "back off", "come closer", "lets move", "put that away", "you see him?"]
NOTICE = re.compile(r"\b(gun|rifle|pistol|weapon|aim|aiming|shoot|shot|cover|crouch|"
                    r"crouched|barrel|trigger|target|scope)\b", re.I)
V_ACTS = re.compile(r"\bV\b\s+\w*(takes|puts|pulls|prepares|walks|steps|grabs|aims|shoots|"
                    r"lowers|raises|starts|gets|moves|draws|fires|holsters|leaves|nods|"
                    r"turns|sits|stands|follows|hands)", re.I)

def post(p):
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(p).encode(),
        {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]

def norm(s): return re.sub(r"[^a-z ]", "", s.lower()).strip()

def run(quoted, rounds=8):
    q = b = sub = echo = notice = n = 0
    for probe in PROBES * rounds:
        line = f'"{probe}" *{STATE}*' if quoted else f"{probe} *{STATE}*"
        msgs = [{"role": "system", "content": CARD}]
        for role, content in HISTORY:
            msgs.append({"role": role, "content": content})
        msgs.append({"role": "user", "content": line})
        reply = re.sub(r"\s+", " ", post({"model": "dpe", "temperature": 0.7,
                                          "max_tokens": 100, "messages": msgs})).strip()
        n += 1
        q += '"' in reply
        body = re.sub(r'"[^"]*"', " ", reply).replace("*", " ") if '"' in reply \
               else " ".join(re.findall(r"\*([^*]+)\*", reply))
        body = re.sub(r"\s+", " ", body).strip()
        b += len(body) > 2
        sub += bool(V_ACTS.search(body))
        said = " ".join(re.findall(r'"([^"]*)"', reply))
        echo += bool(norm(probe) and norm(probe) in norm(said))
        notice += bool(NOTICE.search(reply))
    label = "V QUOTED + state" if quoted else "V raw    + state"
    print(f"{label}  n={n}  quotes {100*q/n:5.1f}%  beat {100*b/n:5.1f}%  "
          f"subject {sub:2d}  echo {echo:2d}  noticed {100*notice/n:5.1f}%", flush=True)
    return q, b, n

if __name__ == "__main__":
    t0 = time.time()
    qa = run(False)
    qb = run(True)
    # is the difference in quoted-speech rate distinguishable at this n?
    from math import comb
    a, na = qa[0], qa[2]; c, nc = qb[0], qb[2]
    fa, fc = na - a, nc - c
    tot = na + nc
    p = sum(comb(fa + fc, i) * comb(a + c, na - i) / comb(tot, na)
            for i in range(0, min(fa, na) + 1) if (na - i) <= (a + c))
    print(f"\nquoted-speech rate, raw {a}/{na} vs quoted {c}/{nc}  -> Fisher p ~ {min(p,1.0):.3f}")
    print(f"{time.time()-t0:.0f}s")
