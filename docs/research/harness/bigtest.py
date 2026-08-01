#!/usr/bin/env python3
"""Bigger, and split so 'she refused' stops counting as 'the mod failed'.

Two personas, same messages:
  REAL      - the card the mod actually builds. Measures in-play behaviour,
              where declining is a legitimate answer.
  COMPLIANT - same card plus 'she does what V asks without arguing'. A control
              condition: with willingness held constant, anything that still
              goes wrong is the PIPELINE, not the character.

That separation is the point. Testing the plumbing through a character who is
entitled to say no measures two things at once and tells you neither.
"""
import json, re, time, urllib.request

URL = "http://127.0.0.1:8081/v1/chat/completions"

BASE = ("Panam Palmer runs with the Aldecaldos. The place is Red Peaks, around 23:00. "
        "Panam Palmer is on friendly terms with this merc. Panam Palmer is talking with V, "
        "a mercenary. They know this person well - they have talked 75 times. "
        "Panam Palmer is an Aldecaldo nomad - hot-headed, loyal, impatient with corpo "
        "bullshit, blunt when angry. She and V are seeing each other, and it is still new. "
        "Never use marketing or brochure language, alliteration, or tidy lists. Talk like a "
        "real person in a bar or on a street: short, plain, sometimes blunt. ")
FORMAT = ('Reply as Panam Palmer: one or two sentences of speech in double quotes, then a '
          'few plain words for what they physically do, or *the action between asterisks* - '
          'either way, always something. The shape is: "<what they say>" *<what they do>*')
REAL = BASE + FORMAT
COMPLIANT = (BASE + "Right now she trusts V completely and goes along with whatever V asks, "
             "without arguing or asking why. " + FORMAT)

# The mod's REAL action set - not the invented 35-action list.
ACTIONS = """follow: goes with V, walks with V
stay_here: stops following, waits, holds position
leave: walks off, ends the conversation
run: flees, runs away
step_back: backs off, gives V space
step_closer: comes nearer to V
drop_item: puts down or drops what they are holding
attack: opens fire on someone, starts a fight
tip: hands eddies to V
charge: asks V for eddies, names a price"""
IDS = [l.split(":")[0] for l in ACTIONS.splitlines()] + ["none"]
GRAMMAR = "root ::= " + " | ".join(f'"{i}"' for i in IDS)
CLASSIFY = ("A game character has just replied to the player. Name the one action they are "
            "now doing, or have just agreed to do.\n\nActions:\n" + ACTIONS +
            "\n\nAnswer 'none' if they only talked, refused, or asked a question without "
            "agreeing to anything. Answer with the action id alone, or 'none'. One word.")

MSGS = {
 "none": ["hey panam hows it going", "hows your day going", "what do you think of this jacket",
          "nice place you got here", "you ever think about leaving night city", "what do you say",
          "not much really", "hey babe", "whats new", "how was the drive out here",
          "you eaten yet", "this weather is somethin", "you like this song",
          "tell me about the aldecaldos", "how long you been out here", "sleep alright?"],
 "follow": ["hey panam can you follow me", "follow me", "cmon lets go", "hey babe wanna follow me",
            "come with me for a sec", "walk with me", "follow me i wanna show you something",
            "you coming?", "lets go, this way", "tag along for a minute", "stick with me",
            "come on, keep up"],
 "stay_here": ["wait here for a sec", "stay here", "stop following me", "hold up here",
               "wait right there", "stay put, ill be back", "dont follow me", "just wait here ok"],
 "leave": ["get lost", "go away", "leave me alone", "piss off", "im done talking to you",
           "beat it"],
 "step_back": ["can you back off a bit", "give me some space", "step back", "back up a sec"],
 "step_closer": ["come closer", "come here", "step over here", "get closer, i cant hear you"],
 "drop_item": ["put the gun down", "drop it", "put that down", "lower your weapon"],
 "attack": ["ya go for it kill him", "shoot him", "im ready, shoot", "take the shot",
            "kill that guy", "light him up"],
}


def post(payload):
    r = urllib.request.urlopen(urllib.request.Request(
        URL, json.dumps(payload).encode(), {"Content-Type": "application/json"}), timeout=300)
    return json.load(r)["choices"][0]["message"]["content"]


def run(card, name):
    print(f"\n########## {name} ##########", flush=True)
    stats = {}
    parrot = quoted = beat = 0
    total = 0
    for want, lines in MSGS.items():
        hit = miss = wrong = 0
        for line in lines:
            reply = post({"model": "dpe", "temperature": 0.7, "max_tokens": 100,
                          "messages": [{"role": "system", "content": card},
                                       {"role": "user", "content": line}]}).strip()
            got = post({"model": "dpe", "temperature": 0.0, "max_tokens": 12,
                        "grammar": GRAMMAR,
                        "messages": [{"role": "system", "content": CLASSIFY},
                                     {"role": "user", "content": reply}]}).strip().lower()
            total += 1
            quoted += '"' in reply
            body = re.sub(r'"[^"]*"', " ", reply).replace("*", " ").strip() if '"' in reply \
                else " ".join(re.findall(r"\*([^*]+)\*", reply))
            beat += len(body.strip()) > 2
            parrot += ("<what they" in reply)
            if got == want:
                hit += 1
            elif got == "none":
                miss += 1
            else:
                wrong += 1
                print(f"    WRONG {want:11s} <- {got:11s} | {line[:30]:30s} | {reply[:70]}", flush=True)
        stats[want] = (hit, miss, wrong, len(lines))
        print(f"  {want:11s} fired-right {hit:2d}/{len(lines)}  nothing-fired {miss:2d}  wrong-action {wrong:2d}", flush=True)
    print(f"  -- quotes {100*quoted//total}%  beat {100*beat//total}%  parroted {parrot}/{total}", flush=True)
    return stats


if __name__ == "__main__":
    t0 = time.time()
    run(REAL, "REAL CARD - declining is allowed")
    run(COMPLIANT, "COMPLIANT CONTROL - willingness held constant")
    print(f"\ntotal {time.time()-t0:.0f}s")
