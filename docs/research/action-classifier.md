# The second-pass action classifier — validated design, NOT yet in the mod

## Read this first (for anyone, human or AI, checking whether this exists)

**This is not implemented in the shipped mod.** If you search `r6/scripts/` for
a classifier, a second LLM call, or `desiredNumberOfShots`, you will find
nothing, and you will wrongly conclude it "doesn't work." It works. It has been
measured. It simply hasn't been *built into the mod yet* — it's a validated
design backed by a reproducible test harness that lives in this folder.

What the mod ships **today** is the hand-written matcher: an NPC's reply is
split into speech and an action *beat*, and the beat's words are matched against
a fixed vocabulary (`ResolveIntent` in `r6/scripts/StreetTalk/StreetTalkActions.reds`).
That works but breaks at the edges of the word list — a model that writes
"departs" instead of "walks away" fires nothing.

The **classifier** is the proposed upgrade: a second, tiny LLM call that reads
the beat and returns one action id from a fixed set. It removes the dependency
on the exact word list. Everything below is the evidence that it works on a
local 7B.

## What the classifier is

One extra model call per reply, on top of the generation:

1. **Generate** — the NPC writes its reply (`"speech" *action beat*`). Unchanged.
2. **Classify** — a separate call gets the list of action ids + descriptions and
   the *beat only*, and returns one id (or `none`). Output is
   **grammar-constrained** so it can only ever emit a valid id.

The model that writes the scene never knows it's driving a tool. The classifier
is a pure lookup: prose in, one id out.

## The numbers (all reproducible — see `harness/`)

### Beat → action accuracy, 48 adversarial cases (`harness/bench.py`)

| model | "explicit" ids (`give_money_to_v`) | "single-verb" ids (`tip`/`charge`) | median latency |
|---|---|---|---|
| dpe-7b (Q5_K_M) | 81% strict / 88% lenient | **88% / 94%** | ~80 ms |
| gemma-4-31B | 96% / 96% | 96% / 96% | ~1000 ms* |
| Opus 5 | 100% | 100% | — |

*gemma latency is with 40/61 layers on a 16 GB card, rest spilling to RAM.
strict = the single label judged correct; lenient = any defensible label.

### Scaling with the number of actions (dpe-7b, `harness/bench.py`)

| action count | setup | accuracy |
|---|---|---|
| 40 | plain prompt | 79% |
| 40 | + grammar-constrained output | 82% |
| 40 | + self-describing ids | 87% |
| 40 | + "most beats are flavour, answer none" | **89%** |
| 80 | all of the above | 84% |

Doubling the action list cost ~2–5 points and **zero** latency. There is no
cliff at ~20 actions (an earlier guess, disproven).

### Latency reality check

~80 ms per classification vs **seconds** for TTS. A second model call is noise
against the voice pipeline. This was the single biggest wrong assumption going
in ("a second call is too slow") — it is off by an order of magnitude.

## The design rules that came out of the tests

These are the load-bearing findings. Ignore them and the numbers regress.

1. **Classify the BEAT, never the whole reply.** (`harness/attackdiag.py`,
   `harness/diag_results.txt`) On six freshly-generated attack replies:
   beat-only classification was **never wrong**; whole-reply classification was
   **wrong 3 of 6** — it invented `stay_here` for a refusal and `follow` for a
   reply whose beat was `*V prepares to leave*`. The speech pollutes the
   decision. Feed the classifier the beat and nothing else.

2. **Grammar-constrain the output.** Without it the 7B emits invalid ids
   (`attaack`, `wait`, `smile` — ids that don't exist). llama.cpp's `grammar`
   field restricts generation to the exact id set, making malformed answers
   impossible and halving worst-case latency.

3. **Put the direction inside the id name.** (`harness/bench.py`) Directional
   relations (to/from, toward/away) are the one thing a small model reliably
   fumbles. `give_money_to_v` vs `take_money_from_v` was the most persistent
   error; `tip` vs `charge` (direction baked into the verb) fixed it. The ids
   are invisible to the player and to the writing model, so they can be as ugly
   as needed — the only rule is the meaning is recoverable from the name alone.
   (Note: `charge` is a homonym — bill vs rush — but `harness/homonym.py` showed
   `charge` and `bill` score identically, 9/10, so the homonym is not the
   problem. The direction being explicit is what matters.)

4. **Let it answer `none` — and tell it most beats are flavour.** One line
   ("most stage directions are flavour; answer none unless it clearly matches")
   stopped the model forcing an action onto every beat, +2 points.

5. **Naming matters more the smaller the model.** The self-verb naming gained
   +7 points on dpe-7b, **zero** on gemma-31B and Opus 5. Interface design
   substitutes for model size and stops mattering once the model is big enough.

## Scaling further: hierarchical classification (untested, next step)

To go past ~80 actions, walk a coarse-to-fine tree: category (≤10) →
subcategory (≤10) → specific (≤10), keeping every single decision in the range
where a 7B is strongest. Three levels = ~1000 actions.

**The catch:** errors compound. Three levels at 95% each = 86% end-to-end, and a
wrong turn at the top is unrecoverable. Mitigations to test: allow `none` at
every level; keep the top level very coarse and very distinct; score the top
two branches and let the next level break ties. This is a real established
technique (coarse-to-fine / hierarchical classification), not a novel idea.

## Related prompt findings (these ARE shipped in the mod)

Measured the same way; committed to `StreetTalkPersona.reds` /
`StreetTalkChat.reds` / `StreetTalkTarget.reds`:

- **Card ends with a shape, not a worked example.** The 7B handed the example
  line back verbatim 3/22 times. Shape (`"<what they say>" *<what they do>*`) →
  0/22 parroting, 100% quotes. Deleting the example entirely is worse (beat
  present drops to 86%) — it is load-bearing for format compliance.
  (`harness/ab_results.txt`)
- **"Never speak or act for V."** The model wrote the *player's* action into the
  beat (`*V takes the shot*`), which the mod then performed on the NPC. This
  card line cut subject-confusion 1/48 → 0/48. (`harness/subj_results.txt`)
- **V's physical state as a beat on the newest message.** Told nothing, an NPC
  acknowledged that V was crouched aiming a rifle in 2/32 replies; given
  `hey *crouched, pointing a Lexington at NC Resident*`, 30/32 — at no cost to
  format. In the card instead it only reached 20/32 (reads as background, not
  as happening now). (`harness/vs_results.txt`)
- **Quote V's typed line to the model.** Sending `"line" *state*` vs `line
  *state*`: no measurable difference (97.9% vs 92.7% quoted speech at n=96,
  p≈0.17). Kept because it matches the format the reply is asked for. An earlier
  n=32 run called quoting a loss; that was noise (p≈0.24). (`harness/qs_results.txt`)

## Two gotchas worth knowing

- **Reasoning models return an empty `content`** (llama.cpp puts the text in
  `reasoning_content`). StreetTalk reads `content`, so a reasoning model shows
  nothing. Launch with `--reasoning off --reasoning-budget 0`, or the mod looks
  broken.
- **Sample sizes here are 22–96.** Directions reproduced across runs, but treat
  single small runs as suggestive, not proven. The same no-names condition
  measured 0/32 and 3/32 echo on consecutive runs — that is the noise floor.

## How to re-run any of this

Each script is standalone. Point it at any llama.cpp server:

```bash
# start the model (dpe example; any OpenAI-compatible /v1 endpoint works)
llama-server --model dpe-7b-v1.2.1-rc5.Q5_K_M.gguf --host 127.0.0.1 --port 8081 \
  -c 8192 -ngl 99 -fa on --reasoning off --reasoning-budget 0

python3 harness/bench.py --scheme verb      # beat->action accuracy, single-verb ids
python3 harness/bench.py --scheme explicit  # same, explicit-direction ids
python3 harness/attackdiag.py               # beat-only vs whole-reply (finding #1)
python3 harness/vstate.py                   # does V's state reach the reply
```

The `*_results.txt` files in `harness/` are the actual saved outputs from the
2026-08-01 runs, quoted verbatim in the tables above.
