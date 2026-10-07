## Review before the pull request (preflight)

Every change is reviewed before it becomes a pull request, and again after any change made in response to that
review. The reviewer is a machine-local PR-Agent run over the **working tree** - no GitHub round trip, and no
commit required:

```sh
preflight review   # working tree vs the remote default branch -> .preflight/review.md + .preflight/review.json
preflight-gate     # exit 0 = pass, 1 = changes required or key issues, 2 = security concerns, 3 = no review yet
```

`preflight review` reviews what is on disk: committed work **plus uncommitted and untracked changes**. Its diff
comes from a throwaway snapshot of the working tree, so reviewing never stages, commits or rewrites anything -
the index is untouched and HEAD does not move. (`PREFLIGHT_SCOPE=head preflight review` reviews committed content
only.)

Loop until `preflight-gate` exits 0:

1. Read `.preflight/review.md` (prose) and `.preflight/review.json` (structured:
   `review.key_issues_to_review[]`, `review.security_concerns`, `review.relevant_tests`,
   `review.estimated_effort_to_review_[1-5]`, `review.risk_level`, `review.merge_recommendation`).
2. Fix **every** entry in `key_issues_to_review[]` and anything under `security_concerns` in one pass - the
   review is a single, complete report, so there is no reason to fix one finding and re-run for the next.
3. Re-run `preflight review`, then `preflight-gate`. Repeat until it passes.
4. The branch is then ready for the pull request; committing and pushing are the user's call.

- **Do not commit to be reviewed.** The loop needs no commit - work in the working tree, review, fix, re-review.
  Committing between rounds is what produces a stack of near-identical commits, and the review does not require
  one; commit once, for the pull request, and only when the user asks.
- **The review supplements your test/lint gate, it does not replace it.** A clean review says nothing about
  types, lint or the tests; those still have to pass.
- **`.preflight/` is gitignored and per worktree.** The exclude lives in `.git/info/exclude` (shared by every
  worktree of the clone), so review output is never committed and two worktrees never collide. `preflight` adds
  the exclude itself when a checkout lacks one, and fetches the remote before diffing, so it never compares
  against a stale local default branch.
- **`preflight` and `preflight-gate` are machine-local helpers, not part of the repository.** They live in
  `~/.local/bin`, are driven by `~/.config/preflight/preflight.toml`, and work against any OpenAI-compatible
  endpoint (ClinePass is only the default). Other commands: `preflight describe`, `preflight improve`,
  `preflight ask "<question>"`.
- If the helpers are missing on this machine, install them with the bundle's `install.sh`.

### Make it enforced (recommended): refuse a commit that was not reviewed

The loop above only works if someone remembers to run it. To make the repo **refuse** an unreviewed commit,
commit a pre-commit hook and point git at it - once per clone, and it then covers every worktree:

```sh
cp ~/.config/preflight/githooks/* .githooks/     # ships with the bundle's install.sh
git add .githooks && git commit -m "chore: enforce preflight before commits"
git config core.hooksPath .githooks              # RELATIVE - see the note below
```

Use the **relative** path. An absolute one breaks git worktrees: every worktree would run the hooks
directory of whichever checkout the path names, instead of its own.

What the hook does, and does not do:

- It **verifies** that the content being committed was what `preflight review` reviewed. If you edited
  anything after the last review, or staged a file that was never reviewed, the commit is **blocked** and
  the offending paths are named.
- It **never runs a review** and never stages anything. It does not modify the index, `HEAD`, or the
  working tree - it only reads.
- It is **content-based, not time-based**: there is no expiry. A review counts only while the content it
  covered is exactly what you are committing.
- Reviewed content you are **not** committing is ignored, so `git commit -a` keeps working when untracked
  scratch files are around.
- Deleting a reviewed file is blocked like any other change (`git rm` included): the review has to cover the
  removal too. Re-run `preflight review` and the deletion commits normally.
- Renaming a reviewed file away (`git mv`) and swapping a file for a symlink are blocked as well - both
  leave a path present but no longer doing what the review saw.
- The **first** commit in a repository with no history is allowed but not enforced - `preflight review`
  cannot run before a first commit exists, so blocking would make the hook impossible to adopt.
- `PREFLIGHT_SCOPE=head` reviews cannot be enforced (a head-scope review covers content that already
  exists, and a pre-commit hook runs before the commit it would cover). Use the default worktree scope.
- Deliberate one-off bypass: `git commit --no-verify` (or `PREFLIGHT_SKIP=1`).
- It calls the verifier at `$PREFLIGHT_HOOK`, defaulting to `~/.config/preflight/preflight-hook`. If that
  helper is missing the commit is **refused**, not passed - so re-run the bundle's `install.sh` on a new
  machine, or set `PREFLIGHT_HOOK` to a vendored copy.
- `.preflight/` is left in place on a block so you can read `.preflight/review.md` for the detail. The
  verdict is also stored in `.preflight/review.meta.json`.

Worked example of the intended sequence:

```sh
preflight review          # review the working tree; writes .preflight/review.meta.json
# fix the findings, then re-review until the gate passes
preflight review && preflight-gate
git add -A && git commit -m "feat: ..."     # the hook verifies the reviewed content
```

### Where the preflight bundle lives, and how to get current guidance

The helpers, the config template, and the full docs live in **this bundle's own repository**:

**<https://github.com/413x5/preflight>**

Read it (do not guess) when you need to know how the review loop is *meant* to work, or when something about
`preflight` has changed:

- `README.md` - install, use, and the "using another provider" recipe.
- `ROADMAP.md` - what is planned and what changed recently.
- `docs/DESIGN.md` - how the working-tree snapshot, the commit hook, the gate, and the provider config work.
- `docs/TROUBLESHOOTING.md` - symptoms and fixes (auth, model ids, token budgets, blocked commits).
- `CHANGELOG.md` - version-by-version changes, including any **breaking** rename or env-var change.

It is a private repo; if `gh` is authenticated on this machine, `gh repo view 413x5/preflight` or
`gh api repos/413x5/preflight/contents/README.md` works. When the bundle is updated, re-paste this snippet into
`AGENTS.md` - the command names and env vars here are the contract, and they can change between versions.
