# Roadmap

Work that is agreed but not yet done, plus ideas worth keeping. Nothing here is tied to a date.

## Now

Small, ready to do.

_Nothing outstanding — the initial packaging, publishing, and signing work is done._

## Done

- [x] **Publish the repo.** Private: <https://github.com/413x5/pr-agent>, default branch `main`.
      `gh repo create --source=.` does not work from a worktree session (no `.git` directory), so
      the remote was added by hand and the branch pushed as `main`.
- [x] **Sign the initial commits.** All three (plus the `v0.1.0` tag) are signed and GitHub shows
      `verified: true`. The signed history replaces the earlier unsigned commits.
- [x] **Add CHANGELOG comparison links.** Added link refs at the foot of `CHANGELOG.md`; requires
      the signed `v0.1.0` tag, which is now pushed.

- [x] **Fix `config.fallback_models`.** The upstream default `["gpt-5.6-terra"]` is a bare OpenAI id
      the endpoint rejects (`400 invalid model format` - ids must be `provider/model`; it serves this
      model as `openai/gpt-5.6-terra`), so a failed primary retried against a dead model. Now
      `["openai/cline-pass/glm-5.3-flash"]` in both `files/pr-agent.toml` and the live
      `~/.config/pr-agent/pr-agent.toml`.

## Next

Wanted; needs a little design.

- [ ] **One review packet.** Optionally run `pral review` + `pral improve` together so a coding agent
      gets the findings *and* concrete suggested diffs in a single round (fewer iterations).
- [ ] **Surface `risk_level` / `merge_recommendation` in `pral`'s summary line** (today it prints
      issues/security/effort/tokens only).
- [ ] **`pral --since <ref>`** for a pseudo-incremental review - plain-diff mode has no true
      incremental, so this would re-review only what changed since the last pass.
- [ ] **Pin the PR-Agent version** in `install.sh` (`pr-agent==0.47.0`) for reproducible installs.
- [ ] **Mirror the snippet** into `.github/copilot-instructions.md` and/or `.clinerules` so agents
      that do not read `AGENTS.md` still follow the loop.
- [ ] **Rename the directory** away from `pr-agent` (collides with the upstream project), e.g.
      `pr-agent-setup`.

## Later

Needs a decision or an external dependency.

- [ ] **Layer 2 - post or update a PR comment from the CLI.** Needs a GitHub token. Today the loop is
      local-only; nothing is posted to GitHub.
- [ ] **Layer 3 - GitHub Actions.** `github-action.example.yml` is staged but not activated.
- [ ] **Bot identity.** Decide between a dedicated bot account (works with the CLI), the
      `github-actions[bot]` identity (Actions only), or a GitHub App + webhook server (not
      CLI-compatible). Required before Layer 2/3 can post under its own name.
- [ ] **Pre-push hook** that runs `pral review` + `pral-gate` and blocks a push when the gate fails.

## Ideas

- `model_routing` - send small diffs to a cheaper/faster ClinePass model.
- `pral-gate --json` for machine consumers.
- Watch ClinePass usage quota (5-hour / weekly / monthly) - reviews are token-heavy (~15-23k each).
- Rotate the ClinePass key periodically (it lives in a `chmod 600` file, never in the environment).
- A `LICENSE` (decide: MIT vs proprietary) if this ever leaves the private context.
