# Roadmap

Work that is agreed but not yet done, plus ideas worth keeping. Nothing here is tied to a date.

## Now

Small, ready to do.

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
      no framework and no network: 30 cases (28 offline plus one live end-to-end), one per requirement
      (`REQ-HOOK-01`..`30`, mapped in `tests/README.md`). Every fix in the hook was reverted in turn to
      confirm the matching case fails, and neutering the hook turns 16 offline cases red. Guards the seven
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
