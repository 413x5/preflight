# Design

How the bundle works, and why each non-obvious decision was made.

## The goal

Review a change **before** it becomes a pull request, without a commit and without a GitHub round
trip, and hand the findings back to whatever coding agent is editing the code.

## `preflight` - reviewing the working tree

PR-Agent's plain-diff mode only sees what you hand it as a diff. To review *uncommitted* work,
`preflight` builds a throwaway snapshot of the working tree:

1. a temporary `GIT_INDEX_FILE` is pointed at a scratch file;
2. `git read-tree HEAD` seeds it from `HEAD`;
3. `git add -A` stages the working tree (tracked edits **and** untracked files) into it;
4. `git write-tree` + `git commit-tree` turn it into a synthetic commit (authored as
   `preflight <preflight@localhost>`), with `commit.gpgsign=false` so a global `gpgsign = true` cannot break it;
5. that commit is diffed against the remote default branch.

The real index, `HEAD`, and history are never touched - the scratch index is deleted on exit.
`PREFLIGHT_SCOPE=head` skips all of this and diffs `origin/main...HEAD` instead.

`preflight` also fetches `origin` first (so it never diffs a stale base), resolves the default branch from
`origin/HEAD`, and appends `.preflight/` to the repo's `.git/info/exclude` (per-clone metadata, shared
by every worktree, never committed).

## The ClinePass streaming workaround (provider-specific)

This is the one genuinely **ClinePass-specific** piece; it is not part of the general mechanism.

ClinePass returns a **wrapped** non-streaming envelope (`{"data": ..., "success": true}`) that LiteLLM
cannot normalize. Streaming returns standard SSE, which LiteLLM parses fine. So the config forces
streaming for that host — and only that host:

```toml
[litellm]
custom_llm_provider = "openai"
force_streaming_custom_llm_provider = "openai"
force_streaming_api_base_substrings = ["api.cline.bot"]
```

The substring is matched against the request's `api_base`, so pointing at any other endpoint simply
never matches and the block is inert — nothing to remove. If you reach ClinePass through a proxy,
`PREFLIGHT_FORCE_STREAMING_HOST` (or the value in `preflight.toml`) sets the host to match.

Token budgets are needed here for a related reason: `cline-pass/*` is not in LiteLLM's model table, so
nothing declares the context window and the packing clamp cuts the diff to 32k. Hence
`custom_model_max_tokens` and `max_model_tokens` are set explicitly. For a model LiteLLM *does* know,
set both to `0` and let LiteLLM resolve the window — `0` means "look it up", not "no limit".

Any OpenAI-compatible endpoint that behaves normally needs neither the workaround nor a guessed
budget.

## Secrets

- Live in `~/.config/preflight/.secrets.toml` (`chmod 600`), under `[openai]`, as `key = "..."`.
- `install.sh` symlinks them into the PR-Agent package's `settings/` dir.
- `uv tool upgrade` recreates the venv and drops that symlink, so `preflight` and `preflight-pr` source
  `ensure-link.sh`, which re-creates it on the next run.

The key is never placed in the shell environment.

## Enforcing the review: the commit hook

The loop is only as good as remembering to run it, so the bundle ships a hook (in `files/githooks/`) that a
repo commits into its own `.githooks/` and enables with `git config core.hooksPath .githooks`.

### It verifies; it does not review

The hook **never runs `preflight review`**. It cannot: `pre-commit` runs *before* the commit exists, so a
worktree-scope review would hash content that only *becomes* the commit, and a head-scope review hashes the
*parent*. There is also no way to invoke a run and then return to grade it, and review flags change the
result without changing any hash. So the hook only checks a review that already happened.

It also never reads `preflight review`'s exit code as a verdict: in plain-diff mode `review` exits `0` even
when it finds 20 issues (it returns `1` only for a tool failure). The verdict comes from `preflight-gate`'s
rules, which `preflight` records in `review.meta.json` at review time.

### What it compares, and why content and not time

`preflight review` snapshots the **worktree** (`read-tree HEAD` + `add -A` in a temporary index) and hands
that diff to the model. It records the tree of exactly that snapshot in `review.meta.json` as
`reviewed_tree`, captured on the same temp index - so it is a true record of what the model saw, rather than
a later recomputation.

At commit time the hook computes the **staged** tree (`git write-tree`) and compares:

```sh
git diff-tree -r -M --diff-filter=AM "$reviewed_tree" "$staged_tree"
```

Empty output means everything being committed was reviewed. Anything printed names a path that is being
committed but was never reviewed.

The comparison is **content-based, not time-based**, so there is no clock skew and no expiry window to
reason about: a review counts exactly while the content it covered is what is being committed.

### Why containment, and not the two obvious alternatives

Both alternatives were measured on a real repo rather than reasoned about:

| Situation | strict equality | **containment** | superset |
|---|---|---|---|
| Edit a file after review, then stage | blocked | blocked | blocked |
| Stage a brand-new, never-reviewed file | blocked | blocked | **passes - unsafe** |
| `git commit -a` with an untracked scratch file | **blocked - breaks a common idiom** | passes | passes |
| Commit a subset of the reviewed files | blocked | passes | passes |

- **Superset** (merely require the reviewed tree to cover the staged tree) is unsafe: it lets a brand-new,
  never-reviewed file through.
- **Strict equality** breaks `git commit -a`. `-a` stages tracked modifications but not untracked files,
  while the snapshot includes them, so any non-ignored scratch file or build artifact makes the trees
  differ and the commit fails. That is a common workflow, not a corner case.
- **Containment** is the rule: every path being *committed* must equal that path in the *reviewed* tree,
  and reviewed content that is not being committed is ignored. `D` records (reviewed but not committed)
  are filtered out, which is what keeps `commit -a` working.

Note what containment does **not** permit: committing only part of a reviewed *file* (for example the first
half of its new content) is blocked, because that intermediate version was never reviewed. Only whole,
reviewed versions of paths pass.

### The state it needs, and the state it deliberately does not have

`review.meta.json` inside the artifact dir is the single source of truth. `.preflight/` is **not deleted**
by the hook: leaving it in place lets a blocked review be inspected, each run refreshes it, and deletion
would buy nothing anyway - if someone acts on stale findings the content changes and the comparison fails,
and if they change nothing the recorded verdict was already `fail`.

Consequently the hook is **strictly read-only**: it never touches the index, `HEAD`, the working tree, or
the artifacts. It needs no per-run state of its own.

### Worktrees

A commit can only be verified once it exists, so enforcement is inherently about the commit you are
*making*. Two consequences:

- Use a **relative** `core.hooksPath`. An absolute path points every worktree at the hooks directory of
  whichever checkout it names, instead of the worktree you are in.
- `git rev-parse --git-path preflight/` resolves per worktree, but the hook does not need it: the artifact
  dir is a working-directory path, so it is already per worktree, and each worktree is reviewed and
  committed independently.

## The gate

`preflight-gate` is a small, dependency-free check over `review.json`:

| Exit | Meaning |
|---|---|
| 0 | pass |
| 1 | `merge_recommendation = changes_required`, or key issues present |
| 2 | security concerns present |
| 3 | no review found |

Env knobs: `PREFLIGHT_GATE_ALLOW_ISSUES=1` (ignore key issues), `PREFLIGHT_GATE_MAX_EFFORT=N` (fail above the
estimated effort).

`preflight review` runs the same check to record `gate.verdict` in `review.meta.json`, so the commit hook
and the gate can never disagree about what counts as a pass.
