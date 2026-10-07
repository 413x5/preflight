## Review before the pull request (PR-Agent)

Every change is reviewed before it becomes a pull request, and again after any change made in response to that
review. The reviewer is a machine-local PR-Agent run over the **working tree** - no GitHub round trip, and no
commit required:

```sh
pral review   # working tree vs the remote default branch -> .pr-agent/review.md + .pr-agent/review.json
pral-gate     # exit 0 = pass, 1 = changes required or key issues, 2 = security concerns, 3 = no review yet
```

`pral review` reviews what is on disk: committed work **plus uncommitted and untracked changes**. Its diff comes
from a throwaway snapshot of the working tree, so reviewing never stages, commits or rewrites anything - the
index is untouched and HEAD does not move. (`PRAL_SCOPE=head pral review` reviews committed content only.)

Loop until `pral-gate` exits 0:

1. Read `.pr-agent/review.md` (prose) and `.pr-agent/review.json` (structured:
   `review.key_issues_to_review[]`, `review.security_concerns`, `review.relevant_tests`,
   `review.estimated_effort_to_review_[1-5]`, `review.risk_level`, `review.merge_recommendation`).
2. Fix **every** entry in `key_issues_to_review[]` and anything under `security_concerns` in one pass - the
   review is a single, complete report, so there is no reason to fix one finding and re-run for the next.
3. Re-run `pral review`, then `pral-gate`. Repeat until it passes.
4. The branch is then ready for the pull request; committing and pushing are the user's call.

- **Do not commit to be reviewed.** The loop needs no commit - work in the working tree, review, fix, re-review.
  Committing between rounds is what produces a stack of near-identical commits, and the review does not require
  one; commit once, for the pull request, and only when the user asks.
- **The review supplements your test/lint gate, it does not replace it.** A clean review says nothing about
  types, lint or the tests; those still have to pass.
- **`.pr-agent/` is gitignored and per worktree.** The exclude lives in `.git/info/exclude` (shared by every
  worktree of the clone), so review output is never committed and two worktrees never collide. `pral` adds the
  exclude itself when a checkout lacks one, and fetches the remote before diffing, so it never compares against a
  stale local default branch.
- **`pral` and `pral-gate` are machine-local helpers, not part of the repository.** They live in `~/.local/bin`;
  `pral` is PR-Agent configured against the ClinePass model endpoint. Other commands: `pral describe`,
  `pral improve`, `pral ask "<question>"`.
- If the helpers are missing on this machine, install them with the PR-Agent bundle's `install.sh`.
