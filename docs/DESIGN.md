# Design

How the bundle works, and why each non-obvious decision was made.

## The goal

Review a change **before** it becomes a pull request, without a commit and without a GitHub round
trip, and hand the findings back to whatever coding agent is editing the code.

## `pral` - reviewing the working tree

PR-Agent's plain-diff mode only sees what you hand it as a diff. To review *uncommitted* work,
`pral` builds a throwaway snapshot of the working tree:

1. a temporary `GIT_INDEX_FILE` is pointed at a scratch file;
2. `git read-tree HEAD` seeds it from `HEAD`;
3. `git add -A` stages the working tree (tracked edits **and** untracked files) into it;
4. `git write-tree` + `git commit-tree` turn it into a synthetic commit (authored as
   `pral <pral@localhost>`), with `commit.gpgsign=false` so a global `gpgsign = true` cannot break it;
5. that commit is diffed against the remote default branch.

The real index, `HEAD`, and history are never touched - the scratch index is deleted on exit.
`PRAL_SCOPE=head` skips all of this and diffs `origin/main...HEAD` instead.

`pral` also fetches `origin` first (so it never diffs a stale base), resolves the default branch from
`origin/HEAD`, and appends `.pr-agent/` to the repo's `.git/info/exclude` (per-clone metadata, shared
by every worktree, never committed).

## The ClinePass streaming workaround

ClinePass returns a **wrapped** non-streaming envelope (`{"data": ..., "success": true}`) that LiteLLM
cannot normalize. Streaming returns standard SSE, which LiteLLM parses fine. So the config forces
streaming for that host:

```toml
[litellm]
custom_llm_provider = "openai"
force_streaming_custom_llm_provider = "openai"
force_streaming_api_base_substrings = ["api.cline.bot"]
```

`cline-pass/*` is not in LiteLLM's model table, so `custom_model_max_tokens` and `max_model_tokens`
declare the 1M window explicitly (otherwise the packing clamp cuts the diff to 32k).

## Secrets

- Live in `~/.config/pr-agent/.secrets.toml` (`chmod 600`), under `[openai]`, as `key = "..."`.
- `install.sh` symlinks them into the PR-Agent package's `settings/` dir.
- `uv tool upgrade` recreates the venv and drops that symlink, so `pra` and `pral` source
  `ensure-link.sh`, which re-creates it on the next run.

The key is never placed in the shell environment.

## The gate

`pral-gate` is a small, dependency-free check over `review.json`:

| Exit | Meaning |
|---|---|
| 0 | pass |
| 1 | `merge_recommendation = changes_required`, or key issues present |
| 2 | security concerns present |
| 3 | no review found |

Env knobs: `PRAL_GATE_ALLOW_ISSUES=1` (ignore key issues), `PRAL_GATE_MAX_EFFORT=N` (fail above the
estimated effort).
