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
5. that commit is diffed against the base branch.

The real index, `HEAD`, and history are never touched - the scratch index is deleted on exit.
`PREFLIGHT_SCOPE=head` skips all of this and diffs `base...HEAD` instead.

`preflight` also fetches `origin` first, so it never diffs a stale base. The base is the first of these
that resolves to a commit: `PREFLIGHT_BASE` (the explicit override), `origin/HEAD`, the remote's own
`HEAD` (`git ls-remote --symref origin HEAD`, needed because a `--single-branch` clone and a hand-added
remote never create the local `origin/HEAD` symref), then `origin/main`, `origin/master`, `main`,
`master`. If none resolves it fails with exit 4 and names the candidates rather than guessing.

That ordering is not decoration. The earlier version fell through to a bare `main` unchecked, so in a
repository whose default branch was anything else `git diff main...HEAD` was fatal, pr-agent exited 2
with "No diff content received", and the artifact dir was left **empty** - which the commit hook reads
as "no review found" and turns into a block on every later commit. A base-resolution failure has to be
loud, because its silent form is indistinguishable from an unreviewed tree.

Finally it appends `.preflight/` to the repo's `.git/info/exclude` (per-clone metadata, shared by every
worktree, never committed).

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
git diff-tree -r -M -z --diff-filter=ACMRTU --name-only "$reviewed_tree" "$staged_tree"
```

Empty output means every path being committed matches the reviewed tree. Anything printed names a path
that is being committed but was never reviewed.

The filter must be `ACMRTU`, not `AM`. With rename detection on, a moved file is neither added nor
modified, and a changed file type (regular file to symlink, say) is `T` - so an `AM`-only filter reports
**nothing** for `git mv auth.py auth_disabled.py` or for a file swapped for a symlink, and both would
commit unreviewed.

A second comparison picks up removals, because deleting reviewed code is how a guard disappears
unnoticed:

```sh
git diff-tree -r -M -z --diff-filter=D --name-only "$reviewed_tree" "$staged_tree"
```

### Why every listing uses `-z`

Without `-z`, `--name-only` **quotes** any path that needs it - wrapping it in double quotes and
backslash-escaping it - and `core.quotePath` cannot turn that off for the characters that matter (it only
controls bytes above `0x7f`). A quoted name is not a path: handing `"q\"uote.py"` back to git asks about a
file that does not exist. The deletion discriminator below does exactly that, so a reviewed tracked file
named `a"b.py`, `c\d.py` or `café.py` looked like an untracked scratch file and **its deletion committed
unreviewed**. `-z` emits the raw name NUL-terminated, and the names are then handled as bytes rather than
through the shell.

The same reasoning rules out the obvious alternative for the deletion check - `git cat-file -e "HEAD:$path"`
per candidate - for a second, independent reason: interpolating a path into a git argument is exactly the
operation that breaks on a quoted name, and a **gitlink** (submodule) is not a blob, so `cat-file -e
"HEAD:sub"` fails for it and a reviewed submodule removal counted as "not tracked at HEAD" and slipped
through unreviewed. HEAD's paths are read once instead, which lists gitlinks like any other entry:

```sh
git ls-tree -r -z HEAD   # "<mode> <type> <sha>\t<name>", split on the first tab
```

The comparison is **content-based, not time-based**, so there is no clock skew and no expiry window to
reason about: a review counts exactly while the content it covered is what is being committed.

### Why containment, and not the two obvious alternatives

Both alternatives were measured on a real repo rather than reasoned about:

| Situation | strict equality | **containment** | superset |
|---|---|---|---|
| Edit a file after review, then stage | blocked | blocked | blocked |
| Stage a brand-new, never-reviewed file | blocked | blocked | **passes - unsafe** |
| Delete a reviewed tracked file (`git rm`) | blocked | blocked | **passes - unsafe** |
| Rename a reviewed file away (`git mv`) | blocked | blocked | **passes - unsafe** |
| Swap a reviewed file for a symlink | blocked | blocked | **passes - unsafe** |
| Delete a reviewed file whose name git would quote | blocked | blocked | **passes - unsafe** |
| `git commit -a` with an untracked scratch file | **blocked - breaks a common idiom** | passes | passes |
| Commit a subset of the reviewed files | blocked | passes | passes |
| Delete, rename or retype as the review covered it | passes | passes | passes |

- **Superset** (merely require the reviewed tree to cover the staged tree) is unsafe: it lets a brand-new,
  never-reviewed file through, and equally lets reviewed content be deleted, renamed or retyped untouched
  by any review.
- **Strict equality** breaks `git commit -a`. `-a` stages tracked modifications but not untracked files,
  while the snapshot includes them, so any non-ignored scratch file or build artifact makes the trees
  differ and the commit fails. That is a common workflow, not a corner case.
- **Containment** is the rule: every path being *committed* must equal that path in the *reviewed* tree.
  Reviewed content that is not being committed is ignored.

`D` records need one refinement, and it matters. The comparison runs **reviewed -> staged**, where a `D`
means "in the reviewed tree, absent from the staged tree". Two very different things produce that:

- a **tracked file being deleted** - reviewed content going away, which is a change the reviewer never
  saw and is exactly how a guard is removed without being noticed, so it is **blocked**; and
- an **untracked scratch file** that was in the snapshot (the snapshot includes untracked files) and is
  simply not being committed - blocking that would break `git commit -a`, the very thing this rule
  exists to preserve.

The discriminator is `HEAD`: a `D` path that `HEAD` knows is tracked content genuinely being deleted; a
`D` path `HEAD` does not know was never part of the commit's history. Only the former blocks.

Note what containment does **not** permit: committing only part of a reviewed *file* (for example the first
half of its new content) is blocked, because that intermediate version was never reviewed. Deleting a whole
reviewed file is blocked too, for the same reason. A deletion or rename that is *included in the review*
passes normally - re-reviewing is the intended way to accept a removal.

### The first commit is not enforced

A repository with no commits has nothing to protect: the commit being made *is* the initial content, and
`preflight review` cannot run at all before a first commit exists (it needs `HEAD` to diff against, and
exits 3). Blocking there would deadlock adoption - the hook could never be installed before the commit
that installs it. So with no `HEAD` the hook allows the commit and says it is not enforced.

### The state it needs, and the state it deliberately does not have

`review.meta.json` inside the artifact dir is the single source of truth. `.preflight/` is **not deleted**
by the hook: leaving it in place lets a blocked review be inspected, each run refreshes it, and deletion
would buy nothing anyway - if someone acts on stale findings the content changes and the comparison fails,
and if they change nothing the recorded verdict was already `fail`.

Consequently the hook is **strictly read-only**: it never touches the index, `HEAD`, the working tree, or
the artifacts. It needs no per-run state of its own.

One limitation follows from that and is worth stating plainly: the recorded verdict is **not
tamper-evident**. `review.meta.json` is an ordinary file, so anyone who can edit the working tree can edit
it too and fabricate a `pass`. The hook defends against the realistic failure mode - a review being skipped
or stale - not against a determined author who is willing to write their own sidecar. Making the verdict
trustworthy needs a party that can sign or re-derive it (server-side review state, or a check that runs
where the author has no write access), which is a different layer than this hook.

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

## Making one review report everything (why the loop converges)

The loop is `review → fix all findings → re-review`. It is only as good as the claim that *one* review
reports *all* findings, and that claim has two independent failure modes. Both show up the same way - an
agent fixes a finding, re-runs, and gets handed a fresh one - so the two are easy to mistake for each
other, and fixing only one leaves the loop slow.

**The model returns few findings.** `pr_reviewer.num_max_findings` caps how many are returned (upstream
default 3). `preflight.toml` raises it, and also sets `pr_reviewer.extra_instructions` - injected verbatim
into the reviewer's system prompt - to tell the model to work through the whole diff and report every
issue it is confident about, rather than stopping at the first.

**The model was shown only part of the diff.** This is the half `num_max_findings` cannot fix: raising a
cap on *returned* findings does nothing if the diff itself was pruned before the call. When a diff exceeds
the token budget, pr-agent's default is to prune files and review the first patch, so a "complete" review
covers a slice of the tree - and a later run, against different content, surfaces findings that were there
all along. `preflight.toml` therefore sets `enable_large_pr_chunking = true` (`max_number_of_calls = 3`),
which splits an oversized diff, reviews every chunk, and *unions* the per-chunk findings into one review
(the merge rules live in pr-agent's `algo/review_merge.py`). It is inert unless the budget actually leaves
files out, so an ordinary diff still costs exactly one AI call; only a genuinely oversized change pays for
extra calls, and it pays them to avoid an unbounded fix/re-review loop.

Whatever is left uncovered after that is reported rather than hidden. pr-agent appends a coverage footer
to `review.md`, and `preflight` repeats it on the summary line as `coverage=PARTIAL ...`. That line exists
because the summary is what an agent actually reads: `issues=1` on a partial review means "the other files
were not looked at", not "the change is nearly clean". Silent partial coverage is the failure this whole
section guards against - the same shape as the base-resolution and gate failures above, where an
inability to check was indistinguishable from a pass.

The real budget lever is `config.max_model_tokens` / `custom_model_max_tokens`: raise those and the whole
diff fits in a single call. Chunking is the fallback for when it does not.
