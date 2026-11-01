# Roadmap

Work that is agreed but not yet done, plus ideas worth keeping. Nothing here is tied to a date.

This file holds **to-dos only**. A finished item is deleted from here, and its reasoning is recorded in
[`../CHANGELOG.md`](../CHANGELOG.md) (what changed) or in an [ADR](adr/) (why). The one exception is a
`[x]` item under **Open questions on shipped work**, where the tick marks the *shipping* as settled and
the paragraph beneath it as the work - that entry stays until the question is answered.

## Now

Small and ready - no design needed, no experiment to settle first.

_(nothing right now)_

## Next

Wanted; needs design, or an experiment to settle. Two groups:

- **Open questions on shipped work** (`[x]` items, below the experiments) - the shipping paragraph is
  context and the `**Still open**` paragraph under it is the work.
- **Experiments**, each phrased as a question with the result that would settle it. An experiment is
  cheap, reversible and must state what would falsify it; a design item needs a decision first.


### Experiments

- [ ] **Which of the untried levers actually stabilise the finding set?** The convergence test showed the
      blocker is generation variance, and several levers remain untested. The ones below are ordered by
      cost, and each is cheap to run and to revert.

      **Already tested and rejected - do not repeat:** `[config] seed`. It is inert on this endpoint.
      Direct probes with `seed=42`, `seed=1234` and `temperature=0` each returned a different answer every
      time (`['Silent-Crimson-47', 'Brisk-Azure-77', 'Swift-Crimson-47', ...]`), and the endpoint accepted
      the parameter without honouring it. `temperature=0` alone did not stabilise it either. Pinning to
      `seed` also *fails every review* unless `temperature` is 0 - `ValueError: Seed (42) is not supported
      with temperature (0.2) > 0` - on the primary and the fallback model, so it is a pair or nothing.

      **Rejected on reading the source - do not run these:** two entries previously listed here as levers
      are not levers for `review` at all, so running them would return "no effect" and prove nothing.
      `model_reasoning` is reached only from `pr_code_suggestions.py` (the `improve` command, which
      already self-reflects and drops by `suggestions_score_threshold`), while `pr_reviewer.py` always
      calls with `ModelType.REGULAR`. `[config] duplicate_examples` is read by no code in v0.49.0 - it <!-- doc-path-ok: names a key that does NOT exist, in order to warn against it -->
      appears only in `_help_docs/usage-guide/changing_a_model.md`, not in `configuration.toml` and not in
      any `.py`.

      Untried, cheapest first:
      1. **A smaller diff per review.** The variance may scale with how many plausible concerns a diff
         admits. The `commit` scope is roughly a tenth the size of a branch diff and reviews in seconds,
         so this is testable immediately: review one commit three times and compare the finding SETS,
         not the counts.
      2. **A stronger model.** pr-agent's own recommendation (see below) is that structured output at this
         input size is what separates commercial models from the rest, which is exactly the failure.

      What would settle it: for each lever, review the same content three times and compare the finding
      SETS. A lever that leaves the sets different has not fixed the thing we measured.

- [x] **`additional_reasoning_effort_models` is now derived, not configured.** When a profile sets
      `reasoning_effort`, the renderer registers that profile's model in `additional_reasoning_effort_models`
      automatically, so a configured effort reaches the provider instead of being read, logged and dropped.
      The key is refused by name in settings.toml, profile config and .preflight.toml (it is derived, not
      configured). The open question ("is a visible failure worth sending a reasoning budget we have not
      chosen?") is thereby answered in the negative for the registration itself: the bundle still sets no
      `reasoning_effort` value, so pr-agent's `medium` default applies unless the operator opts in on a
      profile, and the registration only makes an *opted-in* effort arrive. A provider-side error on an
      unsupported value still surfaces, because the value is forwarded.
      **Still open:** whether to expose `reasoning_effort` as a profile knob in the shipped example (it is
      already listed as a knob there, commented by absence - the example does not set it).

- [ ] **Does removing `extra_instructions` help or just make the model under-report?** The injected text
      was removed because capturing the literal prompt showed it arguing against pr-agent's own guidance
      in the same system prompt (which says "prefer not reporting over guessing" and "an empty list is
      acceptable") by asserting "most real diffs have several". It was the only text in the prompt pushing
      toward generating findings. Unproven either way: compare the next reviews against `new=N/M` and
      finding volume. Reverting is one config block. Details in `CHANGELOG.md`; the capture method is in
      `docs/runbooks/troubleshooting.md`.

      **What we now know sits against it:** pr-agent's FAQ recommends the **default configuration** for
      reducing noise, and names score thresholds and `extra_instructions` as the levers to *add* when
      feedback is too noisy. Our `extra_instructions` was one of those levers applied in the wrong
      direction, so the cascade was not only sampling variance - a noise knob was deliberately turned up.
      The finding cap is the other half of that trade-off: it is raised well above upstream's default,
      which is what the cap is for, but it is also a lever in the noise direction. Its shipped value is in
      [`config/settings.toml.example`](../config/settings.toml.example) rather than repeated here.

### Open questions on shipped work

- [x] **Make the post-run hang survivable, and stop it hiding the counts.** `preflight-code review` writes
      its artifacts and then sometimes never exits (sleeping in `kevent`, or spinning in the asyncio
      loop), because pr-agent's post-run callback drain blocks after the review is
      finished. The helper now reads the summary from `review.json` *before* waiting, so a hang cannot hide
      `issues=`/`new=`/`coverage=`, and it stops a process that has not exited `PREFLIGHT_SHUTDOWN_WAIT`
      seconds (default 120) after writing the artifact - reporting it, succeeding anyway, and still
      recording the sidecar, so a saved run does not become a blocked commit. The review's own wait is
      bounded too (an hour by default), because a pr-agent that hangs before writing anything is the same
      fault one phase earlier; a run stopped without an artifact keeps its non-zero status. Guarded by
      `REQ-HOOK-32` (fake `pr-agent` scripts, under a watchdog).

      **Still open, and deliberately not papered over:** the hang itself is not fixed, only made
      survivable, and its cause is still not isolated. Two contributors remain candidates - the forced
      streaming endpoint, and completion volume. Several routine reviews during this work did *not* hang at
      all, so it is intermittent. The experiments a future session should run, in order of cost:
      1. **`[litellm] callback_timeout_seconds`** (the drain's own budget). The earlier attempt used
         `[config]`, which pr-agent ignores, so it proved nothing. Set it under `[litellm]` and see whether
         the process exits promptly. If it does not, the block is inside the stream/transport and no config
         key will fix it.
      2. **Reasoning volume.** The strongest correlation found so far is completion volume, and
         `reasoning_effort` is the largest lever on it (see the item below) - so confirm whether the hang
         still reproduces at the much lower output this now produces.
      3. **Streaming.** Point at a non-streaming endpoint and re-test, to separate the SSE connection from
         the callback drain.
- [ ] **Re-measure the reasoning budget before pinning it again (REVERTED, read this).** The bundle used
      to set `[config] reasoning_effort = "low"` plus `additional_reasoning_effort_models`. Both keys are
      now removed; what that means for forwarding is in [`docs/architecture.md`](architecture.md). The reason the
      pin was reverted: it rested on interleaved arms
      measured on **one synthetic 525-line diff** (mean ~18.6s / ~4,051 completion tokens unforwarded
      versus ~9.2s / ~1,689 with `low`), and it did not reproduce on real work - four consecutive reviews
      of this repo's own branch at `low` spent 23k-34k completion tokens (60-68% of each run's total) and
      ranged 1m19s-2m30s on similar diffs. The synthetic number was never evidence about real content. To
      pin it again: measure on a real branch diff, interleaved, against `new=N/M` as well as wall clock
      (a cheaper round that reports fewer findings just moves the cost to a later round).

      **Still open:** whether the raised `num_max_findings` invites padding (its shipped value is in
      [`config/settings.toml.example`](../config/settings.toml.example)), and `[config] seed` (unset), which
      would pin sampling and stabilise `new=N/M` at the cost of whatever coverage pinning removes.
- [x] **Make pending-commit review the default (the `commit` scope).** Changed the default so
      `preflight-code review` covers the pending commit - HEAD to the working tree, untracked files included -
      instead of the whole branch since the default branch, which is what the tool exists for: reviewing a
      change before it is submitted. Landed as [#5](https://github.com/413x5/preflight/pull/5) - CI green on
      both platforms. The per-commit coverage argument, both branch scopes, and the three `REQ-HOOK-33`
      mutations are documented in `README.md`, `docs/architecture.md` and `tests/README.md`.

      **Still open: it has never been reviewed by the tool itself.** It was committed and pushed without a
      review pass, at the maintainer's direction.

- [x] **Surface `risk_level` / `merge_recommendation` in `preflight-code`'s summary line.** The summary carried
      only the counts the gate fails on (issues, security), so `preflight-code review` could report a change
      the gate then refused, discoverable only by running a second command. Those fields are now on the line
      and degrade to `n/a` when absent. `REQ-HOOK-35` asserts both, and that an omitted field does not
      print an empty or `None` value.
- [x] **Make the hook recipe mode-safe.** Found by reviewing this repo with the tool: `git` ignores a
      non-executable hook, and the documented `cp` recipe depended on a mode that a fresh clone does not
      inherit from the source file. Now `install -m 0755` everywhere, with `REQ-HOOK-36` guarding the
      shipped files' mode on disk and in the index. See `CHANGELOG.md`.
- [x] **Assert the convergence signal on a real run.** The roadmap called for adding `new=` to the live
      `case_e2e_real_review`. That would have cost a *second* keyed model call (a `new=` count needs a
      previous review, and `reset_case` wipes `.preflight`) and still would not run in CI. Instead
      `REQ-HOOK-34` drives the real helper twice against a stub `pr-agent` that writes its artifacts - the
      pattern `REQ-HOOK-32` established. That closes a wiring gap `REQ-HOOK-31` cannot see (it runs the
      counting block standalone, so `emit_summary` never being called would pass it), costs no tokens, and
      runs on every PR.
- [ ] **One review packet.** Optionally run `preflight-code review` + `preflight-code improve` together so a
      coding agent gets the findings *and* concrete suggested diffs in a single round (fewer
      iterations). The single-review completeness work (the finding cap, the coverage line) is
      done; this is the remaining half - not yet a second report per round.
- [ ] **`risk_level` is reported but never enforced - decide what it is for.** The gate reads it only to
      print it; the verdict comes from security/blocking issues. (Effort and `merge_recommendation` were
      removed from the gate entirely - see `CHANGELOG.md`.) Measured over four
      consecutive reviews of this repo it was `low, low, medium, low` on similar finding counts, while
      `merge_recommendation` never moved off `merge_with_caution` - so it is unstable and does not track
      findings (`risk=low` with two key issues was observed). **Two further reviews (the pin/README
      change) reported `risk=n/a` outright** - and that later observation is explained by configuration
      rather than by the model: `require_risk_assessment` is unset, so `risk_level` is not in the schema the
      model is asked for and the summary line's `n/a` fallback is reporting its absence correctly. The
      instability above was measured while the key was still set, which is why it was removed.

      **So the question is what to do with a field the bundle does not request**: the gate could not gate on
      it as things stand, and re-enabling it just to measure again would add back output nothing acts on -
      the same shape of waste that removed it. The safer shape is an explicit, deterministic policy such
      as `block_on = security,changes_required,issues`, or the existing `PREFLIGHT_GATE_ALLOW_ISSUES=1`
      opt-out. Not yet decided.
- [ ] **`preflight-code --since <ref>`** for a pseudo-incremental review - plain-diff mode has no true
      incremental, so this would re-review only what changed since the last pass.
- [ ] **Remember the last reviewed commit** so a second `preflight-code review` can skip unchanged work.
- [ ] **What should refuse a config dir that is COMMITTED inside the reviewed repository?** The in-repo
      guard covers untracked, unignored files there, and `git add -A` stages a *tracked* file whatever
      `.gitignore` says - so a committed `providers.toml` reaches the model while the guard reports nothing.
      The invariant to decide is which tracked files are a refusal, since an ignore rule cannot be the
      answer and the remedy differs (untrack, or move the config out). A name list cannot be the unit: a
      `providers.toml.bak` or an editor copy holds the same key under a name no list predicts, which is the
      reasoning the untracked half already applies to the directory. Two rounds of reviewing a draft
      implementation with the tool surfaced the shape of the difficulty - a directory-wide rule names
      unrelated tracked files and would untrack them, while a name rule misses backups - so this needs a
      decision about the unit before any code, not another enumeration.

## What upstream's own docs say (checked against the installed v0.49.0)

Read from the package's shipped `_help_docs/` rather than the website, so it matches what we run. Several
items bear directly on the convergence problem, and one contradicts a choice this bundle made.

- **Model choice.** `usage-guide/changing_a_model.md` states it plainly: commercial models (GPT-5, Claude
  Sonnet, Gemini) "have demonstrated robust capabilities in generating **structured output** for code
  analysis tasks with large input", while most open-source models "face challenges with these complex
  tasks", and local models are "suitable for experimentation and learning purposes (mainly for the `ask`
  command), but not suitable for production-level code analysis". For production it recommends commercial
  models. The configuration this repository was developed against is a `flash` model, and the failure
  measured - an unstable finding set on a large diff - is a structured-output failure at input size. This
  is the single most relevant line upstream ships.
- **Noise.** The FAQ recommends the **default configuration** for reducing noise, and lists score
  thresholds and `extra_instructions` as the levers to *add* when feedback is too noisy. This bundle
  raised the finding cap well above default and added our own `extra_instructions` - noise levers turned
  up, relevant context for the cascade. Its value is in
  [`config/settings.toml.example`](../config/settings.toml.example), not repeated here.
- **`reasoning_effort`.** Forwarded only to a model litellm's metadata calls reasoning-capable; add the ID
  to `config.additional_reasoning_effort_models` otherwise, and adding it "surfaces that provider-side
  error instead of the previous silent drop".
- **`seed`.** "set positive value to fix the seed (and ensure temperature=0)". The docs make the pair
  explicit but claim reproducibility without noting that a provider may accept `seed` and ignore it - ours
  does (see the experiment above).
- **Default `temperature = 0.2`**, with `no_temperature_models` for models that reject temperature
  (o1/o3/o4-mini, `gpt-5.x-codex`, adaptive-thinking Claude).
- **`model_reasoning`** - a "dedicated reasoning model for self-reflection", commented out in
  `configuration.toml`: the model generates findings, then a follow-up call scores each 0-10 and drops the
  incorrect ones. Reachable only from `improve` (`pr_code_suggestions.py`), never from `review`.
- **`duplicate_examples`** - documented for weak/local models as duplicating prompt examples "to help the
  model to generate structured output". **Dead in v0.49.0**: present only in
  `_help_docs/usage-guide/changing_a_model.md`, read by no code and not in `configuration.toml`.
- **`improve`'s `suggestions_score_threshold`** - a documented quality filter; the same
  self-reflection/score mechanism as `model_reasoning`.

## Later

Needs a decision or an external dependency.

- [ ] **Layer 2 - post or update a PR comment from the CLI.** Needs a GitHub token. Today the loop is
      local-only; nothing is posted to GitHub.
- [ ] **Layer 3 - GitHub Actions.** No example workflow is committed yet (an earlier note here referred to
      a `github-action.example.yml` that does not exist). It would need the provider key as a repository
      secret, and a review per push is token-heavy.
- [ ] **Bot identity.** Decide between a dedicated bot account (works with the CLI), the
      `github-actions[bot]` identity (Actions only), or a GitHub App + webhook server (not
      CLI-compatible). Required before Layer 2/3 can post under its own name.
- [ ] **Pre-push hook** that reruns `preflight-code review` + `preflight-gate` and blocks a push when the gate
      fails. Secondary to the commit hook: a pushed branch's content equals its commits, which the commit
      hook already covers, and a pre-push check cannot detect a rewritten or already-pushed hash.

## Ideas

- `model_routing` - send small diffs to a cheaper/faster model.
- `preflight-gate --json` for machine consumers.
- A provider-preset layer in `install.sh` (e.g. `PREFLIGHT_PROVIDER=<name>`) so a set of providers can
  be seeded from one variable instead of hand-editing `providers.toml`. Note the constraint: anything
  preset-specific would be an endpoint or a model in this repo, which the provider-agnostic rule in
  [`AGENTS.md`](../AGENTS.md) forbids - so this would have to load a preset the *user* supplies.
- Watch the endpoint's usage quota, where it has one - reviews are token-heavy
  (see [`measurements.md`](measurements.md)).
- Rotate the endpoint key periodically (it lives in a `chmod 600` file, never in the environment).
- **Can `pr-agent doctor` be given this bundle's rendered config?** Today it reports pr-agent's own defaults:
  the doctor path runs before `apply_host_settings()`, which is where `--extra_config_url` is merged, so a
  `✗ no API key` line is expected on a correctly configured bundle. Settling it needs either a pr-agent
  change or a way to feed the same values in that the doctor path does read - worth knowing before pointing
  anyone at `doctor` as a first-run self-check.
