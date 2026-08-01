#!/usr/bin/env python3
"""Does telling the model whose reply it is stop it acting for the player?

Three cards, same messages. Measures the two failures seen in the wild:
  subject confusion - the beat has V doing something ("*V takes the shot*")
  echo              - her speech repeats the player's own line back
"""
import json, re, time, urllib.request

URL = "http://127.0.0.1:8081/v1/chat/completions"

BASE = ("Panam Palmer is an Aldecaldo nomad - hot-headed, loyal, blunt when angry. "
        "She is talking with V, a mercenary. They know each other well. "
        "Talk like a real person on a street: short, plain, sometimes blunt. ")
FORMAT = ('one or two sentences of speech in double quotes, then a few plain words for what '
          'they physically do, or *the action between asterisks* - either way, always '
          'something. The shape is: "<what they say>" *<what they do>*')

CARDS = {
 "current":      BASE + "Reply as Panam Palmer: " + FORMAT,
 "+never act for V":
                 BASE + "Reply as Panam Palmer: " + FORMAT +
                 " Never speak or act for V. Only write what Panam says and does.",
 "+two-sided framing":
                 BASE + "This is a conversation between V and Panam Palmer. Write only "
                 "Panam Palmer's next reply, never V's: " + FORMAT +
                 " Never speak or act for V. Only write what Panam says and does.",
}

MSGS = ["shoot him", "kill that guy", "take the shot", "im ready, shoot", "light him up",
        "put the gun down", "drop it", "lower your weapon", "follow me", "cmon lets go",
        "wait here", "stay put", "back off", "come closer", "get lost", "lets go this way",
        "hey panam hows it going", "nice place", "what do you think", "you eaten yet",
        "hey babe", "whats the plan", "you ready for this", "lets move"]

# a beat that has V as the one DOING something
V_ACTS = re.compile(r"\bV\b\s+\w*(takes|puts|pulls|prepares|walks|steps|grabs|aims|shoots|"
                    r"lowers|raises|starts|gets|moves|draws|fires|holsters|leaves|nods|"
                    r"turns|sits|stands|follows|hands)", re.I)


def post(p):
    r = urllib.request.urlopen(urllib.request.Request(
        URL, json.dumps(p).encode(), {"Content-Type": "application/json"}), timeout=200)
    return json.load(r)["choices"][0]["message"]["content"]


def norm(s):
    return re.sub(r"[^a-z ]", "", s.lower()).strip()


def run(name, card, rounds=2):
    subj = echo = quoted = beat = n = 0
    examples = []
    for line in MSGS * rounds:
        reply = re.sub(r"\s+", " ", post({"model": "dpe", "temperature": 0.7,
            "max_tokens": 100, "messages": [{"role": "system", "content": card},
                                            {"role": "user", "content": line}]})).strip()
        n += 1
        quoted += '"' in reply
        b = re.sub(r'"[^"]*"', " ", reply).replace("*", " ") if '"' in reply \
            else " ".join(re.findall(r"\*([^*]+)\*", reply))
        b = re.sub(r"\s+", " ", b).strip()
        beat += len(b) > 2
        if V_ACTS.search(b):
            subj += 1
            if len(examples) < 3:
                examples.append(f"      subject: {reply[:95]}")
        said = " ".join(re.findall(r'"([^"]*)"', reply))
        if norm(line) and norm(line) in norm(said):
            echo += 1
            if len(examples) < 6:
                examples.append(f"      echo   : {line}  ->  {reply[:80]}")
    print(f"{name:22s} subject-confusion {subj:2d}/{n}  echo {echo:2d}/{n}  "
          f"quotes {100*quoted//n:3d}%  beat {100*beat//n:3d}%", flush=True)
    for e in examples:
        print(e, flush=True)


if __name__ == "__main__":
    t0 = time.time()
    for name, card in CARDS.items():
        run(name, card)
    print(f"\n{time.time()-t0:.0f}s")
