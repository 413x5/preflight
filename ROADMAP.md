# Roadmap

Work that is agreed but not yet done, plus ideas worth keeping. Nothing here is tied to a date.

## Now

Small, ready to do.

- [ ] **Finish the `commit` scope.** See the handoff under **Next** - it is the one item with an unfinished
      implementation already in the working tree, so start there.
- [ ] **Pin the PR-Agent version** in `install.sh` (`pr-agent==0.47.0`) for reproducible installs.
- [ ] **Mirror the snippet** into `.github/copilot-instructions.md` and/or `.clinerules` so agents
      that do not read `AGENTS.md` still follow the loop.

## Done

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

Wanted; needs a little design.

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
- [x] **Make the model call cheaper and faster - the reasoning budget was unset and invisible.** A review
      of a ~500-line diff reported ~23,500 completion tokens in 111s, of which only ~2,500 characters
      reached `review.md`; the rest was hidden reasoning, so a slow review read as a slow provider rather
      than as an unset budget. `[config] reasoning_effort` now takes effect - which needed `[config]
      additional_reasoning_effort_models` as well, because pr-agent forwards the setting only to a model
      litellm's metadata calls reasoning-capable and `cline-pass/*` is not in that table (`REQ-HOOK-29` and
      CI assert both keys). Measured with the arms INTERLEAVED on one diff (mean **~18.6s / ~4,051
      completion tokens** unforwarded, versus **~9.2s / ~1,689** with `low` forwarded). A first sequential
      pass overstated the gap as 22-38s vs 14s; a later default run took 11s, so interleaving is what
      separates the setting from endpoint load. The lesson is recorded in `docs/TROUBLESHOOTING.md`.

      **Still open:** whether the reduction holds on the real branch diff (that measurement is a synthetic
      525-line diff, not the ~2k-line branch), and whether `num_max_findings = 20` invites padding now that
      rounds are cheap. Also unmeasured: `[config] seed`, which would pin sampling and stabilise `new=N/M`
      at the cost of whatever coverage pinning removes - left unset deliberately, and documented as the
      lever to reach for if the count never settles.
- [ ] **Finish the `commit` scope: make pending-commit review the default (HANDOFF - read this first).**
      The goal, stated by the maintainer: *"we want a way to review a commit before it is submitted, to
      catch bugs early on and for a dev/agent to fix before committing."* The current default does not do
      that - `preflight review` reviews **the whole branch since the default branch**, which is the wrong
      product for the stated goal and the reason a routine review costs ~25k prompt tokens and minutes of
      wall clock.

      **State of the working tree (read before touching anything).**

      **Nothing here is committed.** `git log -1` is still the merge of PR #4, and all of the work described
      below is sitting uncommitted in the working tree of the session that wrote it (12 files, ~722
      insertions). A new session should decide first whether to land that work as one or two commits before
      adding to it - the two logical changes are *"the reasoning budget + bounded shutdown"* (complete,
      tested) and *"the `commit` scope"* (partly done, see below).

      Whatever is landed, the commit must be **GPG-signed** and carry no `Co-authored-by` trailer.

      **The change, and why it is small.**

      `files/preflight` already builds a scratch index (`read-tree HEAD` + `add -A` + `write-tree`) for the
      `worktree` scope, then diffs `${base}...${synth}`. The new default reuses that exact tree and changes
      only the diff line:

      ```sh
      diff_ref='HEAD'        # was: diff_ref="${base}...${synth}"
      ```

      Verified: `git diff HEAD <tree>` is identical to `git diff --cached`. No base, no remote, no
      `commit-tree`. `hook_tree="$tree"` is set identically in both branches, so the hook's containment
      check is **unaffected** - it compares every path being committed against `reviewed_tree`, and a
      `commit`-scope review records precisely that tree.

      **Why per-commit review is *complete*, not merely cheaper.**

      This is the design argument, and it is why the scope change does not weaken coverage. A PR is usually
      one commit at the end; when it is several, each is reviewed as it is made. Containment makes that an
      induction rather than a hope: the hook binds **content, not time** (it deliberately does *not* check
      that the recorded `HEAD` equals `HEAD`, because that "would forbid splitting one reviewed change
      across commits"), and it compares `reviewed_tree -> staged_tree`, so it constrains only the commit
      being made. Therefore every commit was reviewed against the tree it committed, and the union covers
      the branch. A branch review, by contrast, is a *sample* of the final state - subject to token-budget
      pruning, and it enforces nothing.

      **DONE and committed.** The `commit` scope is the default; the branch scopes and the containment rule are
      unchanged.

      - `scope="${PREFLIGHT_SCOPE:-commit}"`, with `commit|worktree|head` validated and an unknown value
        rejected with exit 2.
      - `resolve_base()` and the fetch run **only** for `worktree`/`head`; `commit` sets `base='HEAD'` and
        does no network round trip.
      - `coverage=PARTIAL` is gated to the branch scopes (a pending-commit diff is never pruned, so there is
        nothing to announce).
      - `files/preflight-hook` accepts `commit` **and** `worktree` (it previously required `worktree`, so
        without this the hook would have refused to enforce the new default); `head` is still unenforced.
      - the helper header, `--help`, `README.md`, `docs/DESIGN.md`, `docs/TROUBLESHOOTING.md` and
        `AGENTS-review-snippet.md` all describe the three scopes and the per-commit coverage argument.
      - `REQ-HOOK-33` guards it: the default is `commit`, `worktree` still resolves a base and keeps the
        branch diff, and an unknown scope exits 2. All three were confirmed by mutation (the case fails with
        each applied), and the mutations are listed in `tests/README.md`.
      - `./tests/run.sh hook` (31 cases) and `selfcheck` are green.

      **Still open here (not done):**

      1. **Trim the helper commentary.** This change added a lot of it; the block that handles the review job
         and both waits is roughly half comments. Cut to what is load-bearing and re-measure.
      2. **Review the change with the tool itself and stop at `new=0`.** It was committed and pushed
         *without* a review pass, at the maintainer's direction, so this is the outstanding verification.
         PR: <https://github.com/413x5/preflight/pull/5> - CI green on both platforms, live `e2e` green.

- [ ] **Record the convergence evidence in CI.** `REQ-HOOK-31` covers the counting logic, but nothing
      checks that a real review's summary *emits* `new=` (the live case does not assert it). A cheap
      addition to `case_e2e_real_review`.
- [ ] **One review packet.** Optionally run `preflight review` + `preflight improve` together so a
      coding agent gets the findings *and* concrete suggested diffs in a single round (fewer
      iterations). The single-review completeness work (chunking, `extra_instructions`, the coverage
      line) is done; this is the remaining half - not yet a second report per round.
- [ ] **Surface `risk_level` / `merge_recommendation` in `preflight`'s summary line** (today it prints
      issues/security/effort/tokens only). The gate already uses both.
- [ ] **`preflight --since <ref>`** for a pseudo-incremental review - plain-diff mode has no true
      incremental, so this would re-review only what changed since the last pass.
- [ ] **Remember the last reviewed commit** so a second `preflight review` can skip unchanged work.

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
