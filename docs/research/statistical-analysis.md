# Statistical analysis of the RealTalk prompt experiments

*A post-hoc analysis of the prompt/classifier experiments run 2026-08-01. Written
to be honest about what the data supports, not to justify decisions already made.*

## 1. Summary

Two results are statistically robust and survive correction for multiple
comparisons. Most of the individual prompt tweaks that were adopted are **not**
individually significant at the sample sizes tested; they were adopted on the
combined basis of effect direction, a clear causal mechanism, and negligible
downside — which is a legitimate engineering basis, but is not the same as a
demonstrated effect, and this document does not pretend otherwise.

## 2. Methods

- **Generator:** `dpe-7b-v1.2.1-rc5.Q5_K_M` served by llama.cpp, temperature
  0.7, `--reasoning off`. Classifier calls: temperature 0.0, output
  grammar-constrained to the valid id set.
- **Design:** each experiment is a between-conditions comparison over a fixed
  battery of player messages, holding the character card and (where relevant)
  a fixed conversation history constant across conditions.
- **Outcomes** are binary per trial (parroted / not; beat present / not; noticed
  the situation / not; etc.), scored by deterministic regex, not by human
  judgement.
- **Sample sizes** range from n=22 to n=96 per condition. This is the dominant
  limitation; see §5.
- **Statistics:** proportions are reported with **Wilson score 95% confidence
  intervals** (appropriate near 0 and 1 and at small n, where the normal
  approximation fails). Between-condition comparisons use **Fisher's exact test,
  two-sided**. Reproduction code: `harness/`; this analysis: the script block in
  the project record.

## 3. Results

### 3.1 Point estimates (Wilson 95% CI)

| experiment | condition | rate | 95% CI |
|---|---|---|---|
| **State info reaches reply** (n=32) | no state given | 2/32 = 6.2% | [1.7, 20.1] |
| | state in character card | 20/32 = 62.5% | [45.3, 77.1] |
| | **state as a beat on the message** | **30/32 = 93.8%** | [79.9, 98.3] |
| **Parroting** (n=22) | worked example in card | 3/22 = 13.6% | [4.7, 33.3] |
| | example removed | 1/22 = 4.5% | [0.8, 21.8] |
| | **shape placeholder** | **0/22 = 0.0%** | [0.0, 14.9] |
| Beat present (n=22) | example removed | 19/22 = 86.4% | [66.7, 95.3] |
| | shape placeholder | 22/22 = 100% | [85.1, 100] |
| Subject confusion (n=48) | baseline card | 1/48 = 2.1% | [0.4, 10.9] |
| | + "never act for V" | 0/48 = 0.0% | [0.0, 7.4] |
| Quoted speech present (n=96) | raw player line + state | 89/96 = 92.7% | [85.7, 96.4] |
| | quoted player line + state | 94/96 = 97.9% | [92.7, 99.4] |
| Quoted speech present (n=32) | no name prefixes | 32/32 = 100% | [89.3, 100] |
| | names on both turns | 22/32 = 68.8% | [51.4, 82.0] |
| **Classifier accuracy** (n=48) | dpe-7b, verb ids, strict | 42/48 = 87.5% | [75.3, 94.1] |
| | dpe-7b, verb ids, lenient | 45/48 = 93.8% | [83.2, 97.9] |
| | gemma-31B, strict | 46/48 = 95.8% | [86.0, 98.8] |
| | Opus 5, strict | 48/48 = 100% | [92.6, 100] |

### 3.2 Hypothesis tests (Fisher exact, two-sided)

| comparison | p |
|---|---|
| state-as-beat vs no-state (noticed situation) | **2.7 × 10⁻¹³** |
| state-in-card vs no-state (noticed situation) | **2.9 × 10⁻⁶** |
| state-as-beat vs state-in-card (noticed situation) | 0.0052 |
| names-both vs no-names (quoted speech present) | **0.00085** |
| shape vs worked-example (parroting) | 0.23 |
| shape vs no-example (beat present) | 0.23 |
| "never act for V" vs baseline (subject confusion) | 1.0 |
| "never act for V" vs baseline (echo) | 0.52 |
| quoted vs raw player line (quoted speech, n=96) | 0.17 |
| dpe-7b verb-ids vs explicit-ids (classifier strict) | 0.58 |

## 4. Interpretation, calibrated to the evidence

**Multiple comparisons.** Roughly 12 comparisons were made across the session.
A Bonferroni correction for a family-wise α = 0.05 sets the per-test threshold
at **0.0042**. Applying it:

- **Survives:** state-as-beat vs no-state (p ≈ 3e-13), state-in-card vs no-state
  (p ≈ 3e-6), names-both vs no-names (p ≈ 0.0009).
- **Does not survive:** everything else, including state-as-beat vs
  state-in-card (p = 0.0052, significant uncorrected, fails correction).

**What this licenses as a claim:**

1. **Giving the model the player's physical situation dramatically changes the
   reply** (6% → 94% acknowledgement). This is the one large, unambiguous,
   correction-surviving effect in the entire session. Whether it is delivered as
   a beat or in the card, the effect is real; the beat-vs-card difference is
   suggestive (favouring the beat) but not established.

2. **Name-prefixing both conversational turns degrades quoted-speech
   compliance** (100% → 69%). A real, correction-surviving harm. This is why the
   feature was rejected.

3. **The classifier is accurate but the interval is wide.** dpe-7b at
   87.5% has a 95% CI of [75.3, 94.1] — the point estimate is good, but n=48
   cannot distinguish "88%" from "80%" or "94%". The larger models are tighter
   and clearly better. Ranking (Opus > gemma > dpe) is consistent with the
   point estimates but only the model-size trend, not the exact gaps, is
   supported.

4. **The shape-vs-example, never-act-for-V, and quoting changes are NOT
   individually significant.** Parroting 3/22 → 0/22 is p = 0.23. These were
   adopted because (a) the effect points the right way, (b) there is a concrete
   mechanism (the example is the last token before generation; the model copies
   it), and (c) the downside is zero or negative. That is a defensible
   engineering decision. It is **not** a demonstrated effect, and reporting it
   as one would be wrong.

## 5. Limitations (the honest part)

- **Underpowered.** To detect a 14% → 0% parroting difference at 80% power
  (Fisher, α = 0.05) needs roughly n ≈ 60–70 per arm, not 22. Most single
  experiments here are exploratory.
- **Garden of forking paths.** These are post-hoc comparisons chosen during an
  interactive session, not pre-registered. The Bonferroni correction in §4 is a
  blunt instrument and the true family-wise error rate is unknown, because the
  number of *implicit* comparisons (variants considered and discarded) is larger
  than 12.
- **Test–retest noise is real and measured.** The identical no-names condition
  produced echo rates of 3/32 and 0/32 on consecutive runs. Run-to-run variance
  at this scale is comparable to several of the effects reported as findings.
  Any single small run should be read as suggestive.
- **Single generator, single character, single quantization.** Nothing here
  establishes generalization across models, characters, or quant levels. The
  classifier battery (§3.1) is the one place three models were compared, and
  even there each is n=48.
- **Regex-scored outcomes** are proxies. "Noticed the situation" counts
  keyword presence, not whether the writing is *good*; "beat present" counts
  length, not usefulness.

## 6. Bottom line for a reader deciding whether to trust this

The situational-awareness result and the names-harm result are solid. The
classifier point estimates are good with honestly wide intervals and a clear
model-size ordering. The remaining prompt tweaks are reasonable engineering
calls supported by mechanism and direction, not by statistical significance,
and are labelled as such throughout. Everything is reproducible from `harness/`.
