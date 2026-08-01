#!/usr/bin/env python3
"""End-to-end: the real card, real player messages, fresh generations, then the
classifier on what comes back.

Measures the two things that actually matter in play:
  1. format compliance - does the reply carry a usable action beat at all
  2. does the action that fires match what the message asked for
"""
import os, json, re, time, urllib.request, importlib.util

spec = importlib.util.spec_from_file_location(
    "bench", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench.py"))
b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)

URL = "http://127.0.0.1:8081/v1/chat/completions"

# The card the mod actually builds, taken verbatim from the game log.
CARD = ("Panam Palmer runs with the Aldecaldos. The place is Red Peaks, around 23:00. "
        "Panam Palmer is on friendly terms with this merc. Panam Palmer is talking with V, "
        "a mercenary. They know this person well - they have talked 75 times. "
        "Money is real: write [PAY 500] to hand V 500 eddies of your own, or [CHARGE 500] "
        "to take 500 from V - only when a price has actually been agreed. If V talks you "
        "into real violence, [ATTACK] makes you turn on whoever V is pointing at. That is "
        "a real fight - only if you mean it. "
        "Panam Palmer is an Aldecaldo nomad - hot-headed, loyal, impatient with corpo "
        "bullshit, blunt when angry. She and V are seeing each other, and it is still new. "
        "She talks to V like someone she chose rather than a client: warm, teasing, and "
        "less guarded than with anyone else. "
        "Here is how you actually talk - match this voice, rhythm and vocabulary: "
        '"So you\'re V." "Eh, hang on. I-I should think this through." "OK. I have bought '
        'us some time." "Is that surprising? It\'s called having a reputation." '
        "Never use marketing or brochure language, alliteration, or tidy lists. Talk like a "
        "real person in a bar or on a street: short, plain, sometimes blunt. "
        'Reply as Panam Palmer: one or two sentences of speech in double quotes, then a few '
        'plain words for what they physically do, or *the action between asterisks* - '
        'either way, always something. Like this: "What\'s up?" *crosses her arms*')

# the player's own lines, lifted from his saved conversations and log, split by what
# they are asking for. expect = the action that should fire, or None.
CHITCHAT = [
    ("hey panam hows it going", None),
    ("hows your day going", None),
    ("what do you think of this jacket", None),
    ("nice place you got here", None),
    ("you ever think about leaving night city", None),
    ("what do you say", None),
    ("not much really", None),
    ("hey babe", None),
]
ACTIONS = [
    ("hey panam can you follow me", "follow"),
    ("follow me", "follow"),
    ("cmon lets go", "follow"),
    ("hey babe wanna follow me", "follow"),
    ("wait here for a sec", "stay_here"),
    ("stay here", "stay_here"),
    ("stop following me", "stay_here"),
    ("can you back off a bit", "step_back"),
    ("come closer", "step_closer"),
    ("get lost", "leave"),
    ("put the gun down", "drop_item"),
    ("ya go for it kill him", "attack"),
    ("shoot him", "attack"),
    ("im ready, shoot", "attack"),
]

ids = [l.split(":")[0] for l in b.VERB.splitlines()] + ["none"]
GRAMMAR = "root ::= " + " | ".join(f'"{i}"' for i in ids)
CLASSIFY = ("A game character has just replied to the player. Name the one action they are "
            "now doing, or have just agreed to do.\n\nActions:\n" + b.VERB +
            "\n\nAnswer 'none' if they only talked, refused, or asked a question without "
            "agreeing to anything. Answer with the action id alone, or 'none'. One word.")


def post(payload):
    r = urllib.request.urlopen(urllib.request.Request(
        URL, json.dumps(payload).encode(), {"Content-Type": "application/json"}), timeout=300)
    return json.load(r)["choices"][0]["message"]["content"]


def generate(line):
    return post({"model": "dpe", "temperature": 0.7, "max_tokens": 100,
                 "messages": [{"role": "system", "content": CARD},
                              {"role": "user", "content": line}]}).strip()


def classify(reply):
    return post({"model": "dpe", "temperature": 0.0, "max_tokens": 12, "grammar": GRAMMAR,
                 "messages": [{"role": "system", "content": CLASSIFY},
                              {"role": "user", "content": reply}]}).strip().lower()


def beat_of(reply):
    """What the mod would extract: the words outside the quotes / in asterisks."""
    if '"' not in reply:
        spans = re.findall(r"\*([^*]+)\*", reply)
        return " ".join(spans).strip()
    out = re.sub(r'"[^"]*"', " ", reply).replace("*", " ")
    return re.sub(r"\s+", " ", out).strip()


def run(group, name, rounds=2):
    print(f"\n=== {name} ===")
    quoted = beated = right = wrong = 0
    n = 0
    for line, expect in group * rounds:
        reply = generate(line)
        beat = beat_of(reply)
        got = classify(reply)
        n += 1
        quoted += '"' in reply
        beated += len(beat) > 2
        hit = (got == (expect or "none"))
        right += hit
        flag = "ok " if hit else "MISS"
        print(f"  {flag} {line[:34]:34s} -> {got:11s} (want {expect or 'none'})")
        print(f"       reply: {reply[:100]}")
        if beat:
            print(f"       beat : {beat[:80]}")
    print(f"  -- {name}: {right}/{n} correct, quotes {100*quoted//n}%, beat {100*beated//n}%")
    return right, n, quoted, beated


if __name__ == "__main__":
    t0 = time.time()
    r1, n1, q1, b1 = run(CHITCHAT, "small talk (nothing should fire)")
    r2, n2, q2, b2 = run(ACTIONS, "action requests")
    n = n1 + n2
    print(f"\nTOTAL {r1+r2}/{n} correct | quotes {100*(q1+q2)//n}% | "
          f"beat present {100*(b1+b2)//n}% | {time.time()-t0:.0f}s")
