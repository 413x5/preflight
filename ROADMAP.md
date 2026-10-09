# Roadmap

Work that is agreed but not yet done, plus ideas worth keeping. Nothing here is tied to a date.

## Now

Small and ready - no design needed, no experiment to settle first.

- [x] **Trim the helper commentary.** `files/preflight` was 210 comment lines of 564
      (37%), most densely the coverage-marker block, the summary function and the review-job block. Now
      137 of 491 (28%). Only comments and two `--help` strings changed; the executable lines are untouched
      and `./tests/run.sh hook` and `selfcheck` are green. What remains is the non-obvious reasoning:
      why the coverage marker matches emitted structure, why the two waits are bounded, why the hook
      binding is content- not time-based, and each trap already hit here.
- [ ] **Pin the PR-Agent version** in `install.sh` (`pr-agent==0.47.0`) for reproducible installs.
- [ ] **Mirror the snippet** into `.github/copilot-instructions.md` and/or `.clinerules` so agents
      that do not read `AGENTS.md` still follow the loop.

## Done

Shipped on `main`; kept for the reasoning behind each change, not as work to pick up.

- [x] **Make the bundle's version answerable, and stop two silent failures** (found by reviewing a
      consuming repo's session log). `preflight --version` / `--help` (and `preflight-gate --help`), with
      the version single-sourced in `files/VERSION` and CI failing if it, the `CHANGELOG` heading and
      `--version` disagree. Fixed base-ref resolution, which used to fall through to an unchecked bare
      `main`: in a repo whose default branch was anything else the diff was fatal, pr-agent exited 2, and
      the **empty** artifact dir then made the commit hook report "no review found" for every later commit
      (now a verified candidate list, `PREFLIGHT_BASE` override, and a loud exit 4). Fixed the
      `post-commit` advisory exiting 0 on a sidecar it could not read - silent in exactly the case it
      exists to report, and already patched by hand in one consuming repo. `install.sh` no longer tells
      you to paste a key you already have. The advisory now has a case (`REQ-HOOK-27`), which it did not
      before, and CI runs a version-consistency check.

- [x] **Enforce the review at commit time.** A repo can now refuse a commit whose content was never
      reviewed: bundled `files/githooks/*` copied into its own `.githooks/` plus a **relative**
      `git config core.hooksPath .githooks`. Content-based (not time-based) binding via tree comparison,
      so an edit after the review or a newly staged unreviewed file blocks the commit; reviewed-but-
      uncommitted content is ignored so `git commit -a` still works. Strictly read-only, fails closed, and
      `git commit --no-verify` / `PREFLIGHT_SKIP=1` bypass deliberately. Opt-in per repo, per clone, and it
      covers every worktree.
- [x] **Test the commit hook.** `tests/run.sh` drives real repositories through the real hook files with
      no framework and no network: one check per requirement (`REQ-HOOK-nn`, mapped in `tests/README.md`).
      Every fix in the hook was reverted in turn to confirm the matching case fails, and the selfcheck
      requires that neutering the hook turns exactly the enforcement-sensitive cases red. Guards the
      bypasses found while building it (unreviewed deletions, renames, symlink typechanges,
      `git rm --cached`, git's quoting of path names, gitlinks, and an unset `HOME`).
- [x] **Add `AGENTS.md`.** Instructions for agents changing this repo, as opposed to
      `AGENTS-review-snippet.md`, which is the block pasted into a consuming repo. Records the hook's
      invariants, the checks to run, and the traps already hit here.
- [x] **Add CI.** `.github/workflows/ci.yml` runs shell syntax checks, an installer dry-run, a TOML check
      and the offline hook suite on Ubuntu and macOS for every PR and push to `main`, plus an `actionlint`
      job. The live-endpoint case stays out of CI so it never depends on a paid key.
- [x] **Rename the bundle to `preflight`.** The old name collided with the upstream `pr-agent`
      project. Commands `pra`/`pral`/`pral-gate` → `preflight-pr`/`preflight`/`preflight-gate`,
      config `~/.config/preflight/preflight.toml`, artifacts `.preflight/`, env `PREFLIGHT_*`.
      The upstream tool keeps the name `pr-agent`, so it now means exactly one thing.
      Repo: <https://github.com/413x5/preflight>.
- [x] **Make the bundle provider-agnostic.** Any OpenAI-compatible endpoint works; ClinePass is the
      built-in default. The force-streaming workaround is now keyed on the `api.cline.bot` literal so
      it goes inert for other endpoints, and `install.sh` exposes overrides for the model, fallbacks,
      both token budgets, and the streaming host.
- [x] **Point the AGENTS snippet at this repo**, so an agent working in another repo can read current
      guidance as the bundle evolves.
- [x] **Publish the repo.** Private: <https://github.com/413x5/preflight>, default branch `main`.
      `gh repo create --source=.` does not work from a worktree session (no `.git` directory), so
      the remote was added by hand and the branch pushed as `main`.
- [x] **Sign the initial commits.** All three (plus the `v0.1.0` tag) are signed and GitHub shows
      `verified: true`. The signed history replaces the earlier unsigned commits.
- [x] **Add CHANGELOG comparison links.** Added link refs at the foot of `CHANGELOG.md`; requires
      the signed `v0.1.0` tag, which is now pushed.
- [x] **Fix `config.fallback_models`.** The upstream default `["gpt-5.6-terra"]` is a bare OpenAI id
      the endpoint rejects (`400 invalid model format` - ids must be `provider/model`; it serves this
      model as `openai/gpt-5.6-terra`), so a failed primary retried against a dead model. Now
      `["openai/cline-pass/glm-5.3-flash"]` in both `files/preflight.toml` and the live
      `~/.config/preflight/preflight.toml`.

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
      time (`['Silent-Crimson-47', 'Brisk-Azure-77', 'Swift-Crimson-47', ...]`), and ClinePass accepts the
      parameter without honouring it. `temperature=0` alone did not stabilise it either. Pinning to
      `seed` also *fails every review* unless `temperature` is 0 - `ValueError: Seed (42) is not supported
      with temperature (0.2) > 0` - on the primary and the fallback model, so it is a pair or nothing.

      Untried, cheapest first:
      1. **A smaller diff per review.** The variance may scale with how many plausible concerns a diff
         admits. The `commit` scope is roughly a tenth the size of a branch diff and reviews in seconds,
         so this is testable immediately: review one commit three times and compare the finding SETS,
         not the counts.
      2. **`model_reasoning`** - a dedicated model for pr-agent's self-reflection (a follow-up call that
         scores each finding 0-10 and drops the incorrect ones). Unused here. It attacks the *other* half
         of the problem: not making generation stable, but filtering the noise it produces.
      3. **`[config] duplicate_examples`** - documented as duplicating the prompt examples "to help the
         model generate structured output" for weaker models. **Verify it still exists first:** it appears
         only in one doc example, not in `configuration.toml` and not in any `.py`, so it may be gone.
      4. **A stronger model.** pr-agent's own recommendation (see below) is that structured output at this
         input size is what separates commercial models from the rest, which is exactly the failure.

      What would settle it: for each lever, review the same content three times and compare the finding
      SETS. A lever that leaves the sets different has not fixed the thing we measured.

- [ ] **Should `additional_reasoning_effort_models` come back, purely so the lever fails visibly?**
      Mechanism and the probe: [`docs/DESIGN.md`](docs/DESIGN.md). Adding the key is what makes a configured
      `reasoning_effort` reach the endpoint at all, and what turns an unsupported value into a
      provider-side error instead of a silent drop - it does not pin a budget, since pr-agent's default
      `medium` would then be sent. So the question is: **is a visible failure worth sending a reasoning
      budget we have not chosen?** If not, leave it out and let DESIGN keep saying the lever is inert here.

- [ ] **Does removing `extra_instructions` help or just make the model under-report?** The injected text
      was removed because capturing the literal prompt showed it arguing against pr-agent's own guidance
      in the same system prompt (which says "prefer not reporting over guessing" and "an empty list is
      acceptable") by asserting "most real diffs have several". It was the only text in the prompt pushing
      toward generating findings. Unproven either way: compare the next reviews against `new=N/M` and
      finding volume. Reverting is one config block. Details in `CHANGELOG.md`; the capture method is in
      `docs/TROUBLESHOOTING.md`.

      **What we now know sits against it:** pr-agent's FAQ recommends the **default configuration** for
      reducing noise, and names score thresholds and `extra_instructions` as the levers to *add* when
      feedback is too noisy. `num_max_findings = 20` (4x the default) and our `extra_instructions` were
      those two levers applied in the wrong direction, so the cascade was not only sampling variance -
      two noise knobs were deliberately turned up.

- [ ] **Give findings a severity tier, so a doc typo does not block a commit.** pr-agent's finding schema
      has **no severity field** (`relevant_file`, `issue_header`, `issue_content`, `start_line`,
      `end_line`), so `preflight-gate` treats every finding alike. A deterministic tier computed from
      `relevant_file` - code and `tests/**` blocking, `*.md`/`docs/**` advisory, unknown blocking - was
      designed and is **not implemented**. Any classifier must normalise the path first: values arrive with
      a trailing newline (`'README.md\n'`), so a naive `endswith('.md')` classifies every doc as code and
      the advisory tier would never fire.

### Open questions on shipped work

- [x] **Make the post-run hang survivable, and stop it hiding the counts.** `preflight review` writes
      both artifacts and then sometimes never exits (4-13 minutes, in two shapes - sleeping in `kevent`,
      spinning in the asyncio loop), because pr-agent's post-run callback drain blocks after the review is
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
      now removed; what that means for forwarding is in [`docs/DESIGN.md`](docs/DESIGN.md). The reason the
      pin was reverted: it rested on interleaved arms
      measured on **one synthetic 525-line diff** (mean ~18.6s / ~4,051 completion tokens unforwarded
      versus ~9.2s / ~1,689 with `low`), and it did not reproduce on real work - four consecutive reviews
      of this repo's own branch at `low` spent 23k-34k completion tokens (60-68% of each run's total) and
      ranged 1m19s-2m30s on similar diffs. The synthetic number was never evidence about real content. To
      pin it again: measure on a real branch diff, interleaved, against `new=N/M` as well as wall clock
      (a cheaper round that reports fewer findings just moves the cost to a later round).

      **Still open:** whether `num_max_findings = 20` invites padding, and `[config] seed` (unset), which
      would pin sampling and stabilise `new=N/M` at the cost of whatever coverage pinning removes.
- [x] **Make pending-commit review the default (the `commit` scope).** Changed the default so
      `preflight review` covers the pending commit - HEAD to the working tree, untracked files included -
      instead of the whole branch since the default branch, which is what the tool exists for: reviewing a
      change before it is submitted. Landed as [#5](https://github.com/413x5/preflight/pull/5) - CI green on
      both platforms. The per-commit coverage argument, both branch scopes, and the three `REQ-HOOK-33`
      mutations are documented in `README.md`, `docs/DESIGN.md` and `tests/README.md`.

      **Still open: it has never been reviewed by the tool itself.** It was committed and pushed without a
      review pass, at the maintainer's direction.

- [x] **Surface `risk_level` / `merge_recommendation` in `preflight`'s summary line.** The summary carried
      only the two counts the gate fails on (issues, security), so `preflight review` could report a change
      the gate then refused, discoverable only by running a second command. Both fields are now on the line
      and degrade to `n/a` when absent. `REQ-HOOK-35` asserts both, and that an omitted field does not
      print an empty or `None` value.
- [x] **Make the hook recipe mode-safe.** Found by reviewing this repo with the tool: `git` ignores a
      non-executable hook, and the documented `cp` recipe depended on a mode that a fresh clone does not
      inherit from the source file. Now `install -m 0755` everywhere, with `REQ-HOOK-36` guarding the
      shipped files' mode on disk and in the index. See `CHANGELOG.md`.
- [x] **Assert the convergence signal on a real run.** The roadmap called for adding `new=` to the live
      `case_e2e_real_review`. That would have cost a *second* keyed model call (a `new=` count needs a
      previous review, and `reset_case` wipes `.preflight`) and still would not run in CI. Instead
      `REQ-HOOK-34` drives the real helper twice against a stub `pr-agent` that writes both artifacts - the
      pattern `REQ-HOOK-32` established. That closes a wiring gap `REQ-HOOK-31` cannot see (it runs the
      counting block standalone, so `emit_summary` never being called would pass it), costs no tokens, and
      runs on every PR.
- [ ] **One review packet.** Optionally run `preflight review` + `preflight improve` together so a
      coding agent gets the findings *and* concrete suggested diffs in a single round (fewer
      iterations). The single-review completeness work (chunking, the coverage line) is
      done; this is the remaining half - not yet a second report per round.
- [ ] **`risk_level` is reported but never enforced - decide what it is for.** The gate reads it only to
      print it; the verdict comes from effort/security/`merge_recommendation`/issues. Measured over four
      consecutive reviews of this repo it was `low, low, medium, low` on similar finding counts, while
      `merge_recommendation` never moved off `merge_with_caution` - so it is unstable and does not track
      findings (`risk=low` with two key issues was observed). Making it a gate input (e.g. "block only
      above low risk") would tie enforcement to the flakiest field; the safer shape is an explicit,
      deterministic policy such as `block_on = security,changes_required,issues`, or the existing
      `PREFLIGHT_GATE_ALLOW_ISSUES=1` opt-out. Not yet decided.
- [ ] **`preflight --since <ref>`** for a pseudo-incremental review - plain-diff mode has no true
      incremental, so this would re-review only what changed since the last pass.
- [ ] **Remember the last reviewed commit** so a second `preflight review` can skip unchanged work.

## What upstream's own docs say (checked against the installed v0.47.0)

Read from the package's shipped `_help_docs/` rather than the website, so it matches what we run. Several
items bear directly on the convergence problem, and one contradicts a choice this bundle made.

- **Model choice.** `usage-guide/changing_a_model.md` states it plainly: commercial models (GPT-5, Claude
  Sonnet, Gemini) "have demonstrated robust capabilities in generating **structured output** for code
  analysis tasks with large input", while most open-source models "face challenges with these complex
  tasks", and local models are "suitable for experimentation and learning purposes (mainly for the `ask`
  command), but not suitable for production-level code analysis". For production it recommends commercial
  models. Our default is a `flash` model, and the failure we measured - an unstable finding set on a
  large diff - is a structured-output failure at input size. This is the single most relevant line
  upstream ships.
- **Noise.** The FAQ recommends the **default configuration** for reducing noise, and lists score
  thresholds and `extra_instructions` as the levers to *add* when feedback is too noisy. This bundle had
  raised `num_max_findings` 4x above default and added our own `extra_instructions`, i.e. two noise
  levers turned up - relevant context for the cascade.
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
  incorrect ones. Unused here; it filters noise rather than stabilising generation.
- **`duplicate_examples`** - documented for weak/local models as duplicating prompt examples "to help the
  model to generate structured output". Verify it still exists before relying on it: it appears in exactly
  one doc example and in no `.py` or in `configuration.toml`.
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
- [ ] **Pre-push hook** that reruns `preflight review` + `preflight-gate` and blocks a push when the gate
      fails. Secondary to the commit hook: a pushed branch's content equals its commits, which the commit
      hook already covers, and a pre-push check cannot detect a rewritten or already-pushed hash.

## Ideas

- `model_routing` - send small diffs to a cheaper/faster model.
- `preflight-gate --json` for machine consumers.
- A provider-preset layer in `install.sh` (e.g. `PREFLIGHT_PROVIDER=openai|openrouter|clinepass`) so
  the common cases need one variable instead of five.
- Watch ClinePass usage quota (5-hour / weekly / monthly) - reviews are token-heavy (~15-23k each).
- Rotate the endpoint key periodically (it lives in a `chmod 600` file, never in the environment).
- A `LICENSE` (decide: MIT vs proprietary) if this ever leaves the private context.
