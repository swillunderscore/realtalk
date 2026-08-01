#!/usr/bin/env python3
"""Do per-turn names help, with real conversation history?

Single-turn tests cannot answer this - there is no history for a name to
disambiguate. So each case runs a 4-turn conversation first, then measures the
5th reply, with names on and off.
"""
import json, re, time, urllib.request

URL = "http://127.0.0.1:8081/v1/chat/completions"
NAME = "Panam Palmer"

CARD = ("Panam Palmer is an Aldecaldo nomad - hot-headed, loyal, blunt when angry. "
        "She is talking with V, a mercenary. They know each other well. "
        "Talk like a real person on a street: short, plain, sometimes blunt. "
        'Reply as Panam Palmer: one or two sentences of speech in double quotes, then a few '
        'plain words for what they physically do, or *the action between asterisks* - either '
        'way, always something. The shape is: "<what they say>" *<what they do>*'
        " Never speak or act for V - only write what they themselves say and do.")

# a short lead-in, then the line under test
HISTORY = [
    ("user", "hey panam you got a sec?"),
    ("assistant", '"Always. What\'s on your mind?" *leans against the truck*'),
    ("user", "was gonna ask about the job tomorrow"),
    ("assistant", '"Nothing\'s changed. In and out, no heroics." *checks her rifle*'),
]
PROBES = ["shoot him", "kill that guy", "take the shot", "put the gun down", "drop it",
          "follow me", "cmon lets go", "wait here", "back off", "come closer", "get lost",
          "lets move", "im ready, shoot", "light him up", "lower your weapon", "stay put"]

V_ACTS = re.compile(r"\bV\b\s+\w*(takes|puts|pulls|prepares|walks|steps|grabs|aims|shoots|"
                    r"lowers|raises|starts|gets|moves|draws|fires|holsters|leaves|nods|"
                    r"turns|sits|stands|follows|hands)", re.I)


def post(p):
    r = urllib.request.urlopen(urllib.request.Request(
        URL, json.dumps(p).encode(), {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]


def norm(s):
    return re.sub(r"[^a-z ]", "", s.lower()).strip()


def run(mode, rounds=2):
    subj = echo = quoted = beat = leaked = n = 0
    for probe in PROBES * rounds:
        msgs = [{"role": "system", "content": CARD}]
        for role, content in HISTORY + [("user", probe)]:
            who = "V" if role == "user" else NAME
            tag = (mode == "both") or (mode == "user" and role == "user")
            msgs.append({"role": role,
                         "content": f"{who}: {content}" if tag else content})
        reply = re.sub(r"\s+", " ", post({"model": "dpe", "temperature": 0.7,
                                          "max_tokens": 100, "messages": msgs})).strip()
        n += 1
        if reply.startswith(NAME + ":"):
            leaked += 1
            reply = reply[len(NAME) + 1:].strip()
        quoted += '"' in reply
        b = re.sub(r'"[^"]*"', " ", reply).replace("*", " ") if '"' in reply \
            else " ".join(re.findall(r"\*([^*]+)\*", reply))
        b = re.sub(r"\s+", " ", b).strip()
        beat += len(b) > 2
        subj += bool(V_ACTS.search(b))
        said = " ".join(re.findall(r'"([^"]*)"', reply))
        echo += bool(norm(probe) and norm(probe) in norm(said))
    label = {"off": "names OFF     ", "both": "names BOTH    ",
             "user": "names USER-ONLY"}[mode]
    print(f"{label} subject {subj:2d}/{n}  echo {echo:2d}/{n}  quotes {100*quoted//n:3d}%  "
          f"beat {100*beat//n:3d}%  name-leak {leaked:2d}/{n}", flush=True)


if __name__ == "__main__":
    t0 = time.time()
    run("off")
    run("both")
    run("user")
    print(f"\n{time.time()-t0:.0f}s")
