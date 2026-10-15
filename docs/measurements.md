# Measurements

The dated numbers, each with the reason it moved. Prose elsewhere in this repository should **point here**
rather than carry a count - a number in a paragraph goes stale silently, and a number that went *down* for
a bad reason (a check that started giving up instead of seeing the app) reads like an improvement.

How to quote anything here: name the date and the conditions. A number without them is not evidence, and
several entries below record exactly that lesson.

## Review cost and duration

| Date | Measurement | Conditions | Why it matters |
|---|---|---|---|
| 2026-10-10 | 23,467 completion tokens / 111s | one ~500-line diff, with only ~2,500 characters reaching `review.md` | Most of a review's cost can be **hidden reasoning** the artifacts do not itemise. A slow review looks like a slow provider when it may be reasoning volume |
| 2026-10-10 | 11s / 2,126 tokens | the *same* diff, different run | The spread on identical content is roughly 10x, so a single run is never a benchmark |
| 2026-10-11 | 23k-34k completion tokens (60-68% of each run's total), 1m19s-2m30s | four consecutive reviews of this repo's own branch, `reasoning_effort = "low"` | **Retired the `low` pin.** The pin had rested on a synthetic arm (below); on real content it did not reproduce |
| 2026-10-11 | ~18.6s / ~4,051 completion tokens unforwarded, vs ~9.2s / ~1,689 forwarded `low` | **synthetic** 525-line diff, interleaved arms | The measurement the `low` pin was based on. It was never evidence about real content, which is why the pin was reverted - see [`roadmap.md`](roadmap.md) |
| 2026-10-12 | ~15-23k tokens | one review through `preflight` | The figure to use when warning that a review is token-heavy. Do not put this in a paragraph - it moves |

## Reliability and variance

| Date | Measurement | Conditions | Why it matters |
|---|---|---|---|
| 2026-10-11 | 0, 2 and 1 findings | the **same bytes**, three separate reviews | Reviews here are non-deterministic, so `new=0` is a judgement signal, not a clean bill of health. This is the measurement that makes generation variance the blocker for loop convergence |
| 2026-10-11 | `seed=42`, `seed=1234`, `temperature=0` - a **different answer every time** | direct probes against this endpoint | `seed` is inert here; the endpoint accepts it without honouring it. Do not re-test it. `seed` also *fails every review* unless `temperature` is 0 (`ValueError: Seed (42) is not supported with temperature (0.2) > 0`), on both the primary and the fallback model |
| 2026-10-10 | `risk_level` = `low, low, medium, low` | four consecutive reviews of this repo, on similar finding counts | The field does not track findings. `merge_recommendation` meanwhile never moved off `merge_with_caution` |
| 2026-10-11 | `risk_level` = `n/a` | **two further** reviews (the pr-agent pin / README change) | On this model the field is not merely unstable but sometimes **absent**, which is why it is reported and not enforced |
| 2026-10-11 | 4-13 minutes | observed hangs, in two shapes (sleeping in `kevent`, spinning in the asyncio loop) | Not a slow review: pr-agent's post-run callback drain blocked *after* the review was written and complete. Why the shutdown wait exists |

## Repository process

| Date | Measurement | Conditions | Why it matters |
|---|---|---|---|
| 2026-10-11 | ~56 lines of executable logic against ~271 lines of comment about it | five review rounds, whose later findings were almost entirely about the writing | The evidence for "change the code the finding requires, and little else". Correcting prose produces more prose, which is a loop with no stopping condition - see [`../AGENTS.md`](../AGENTS.md) |
| 2026-10-11 | 61 of 84 lines were comments (73%) | `config/preflight.toml.example` after a documentation pass | Trimming that comment is what exposed the matching bug (the advisory warned on every default-scope commit) that no test had covered. Comment volume is a place bugs hide, not only a cost |
| 2026-10-12 | 141 references across 14 files | `files/` in the tree before the rename to `src/` (see [ADR 0006](adr/0006-adopt-the-playbook-layout.md)) | The cost side of the rename. Note `CHANGELOG.md` holds path references too, which a blind `sed` cannot rewrite |
| 2026-10-15 | 16 rounds, 842,118 tokens, 4,131s | one feature (the run history), reviewed after every change; 13 of the 16 rounds reported a finding | The cost of a loop that converges slowly, measured end to end rather than estimated. It did converge - the last two rounds were clean - but the number to beat is 2-3, not 16. An earlier clean round was read as permission to keep writing, which reset the signal |
| 2026-10-15 | 9 documentation, 8 test-code and 7 logic findings | the same 24 findings, classified by the fix each required | **17 of the 24 - 71% - went to claims and to tests, not to the feature.** The doc bucket is a copy-and-order problem - a rationale restated in five files, where an edit to the code invalidated its own prose. The test bucket is a falsifiability problem: four assertions in one case could not fail while the suite stayed green. Both are why [`../AGENTS.md`](../AGENTS.md) gained "Assertions must be falsifiable" and "Settle the behaviour before you describe it" |
