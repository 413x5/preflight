## Review before the pull request (preflight)

Every change is reviewed before it becomes a pull request, and again after any change made in response to that
review. The reviewer is a machine-local PR-Agent run over the **working tree** - no GitHub round trip, and no
commit required:

```sh
preflight review   # the pending change (HEAD -> working tree) -> .preflight/review.md + .preflight/review.json
preflight-gate     # exit 0 = pass, 1 = changes required or key issues, 2 = security concerns, 3 = no review yet
```

`preflight --help` lists every command and the environment variables; `preflight --version` reports the
installed bundle version (useful when you are not sure this machine has the current bundle).

`preflight review` reviews **the pending commit**: everything HEAD does not yet contain, tracked and untracked.
Its diff comes from a throwaway snapshot of the working tree, so reviewing never stages, commits or rewrites
anything - the index is untouched and HEAD does not move. Reviewing commit by commit covers a multi-commit
branch completely, because each commit is checked against the tree that was reviewed for it.
(`PREFLIGHT_SCOPE=worktree preflight review` reviews the whole branch against the default branch instead;
`=head` reviews committed content only.)

Loop until `preflight-gate` exits 0:

1. Read `.preflight/review.md` (prose) and `.preflight/review.json` (structured:
   `review.key_issues_to_review[]`, `review.security_concerns`, `review.relevant_tests`,
   `review.estimated_effort_to_review_[1-5]`, `review.risk_level`, `review.merge_recommendation`).
2. Fix **every** entry in `key_issues_to_review[]` and anything under `security_concerns` in one pass - the
   review is a single, complete report, so there is no reason to fix one finding and re-run for the next.
3. Re-run `preflight review`, then `preflight-gate`.
4. Stop when it passes, **or** when the new run adds nothing you did not already answer (see below).
5. The branch is then ready for the pull request; committing and pushing are the user's call.

### Stop condition: fix new findings, answer repeats

The loop converges on *new* findings, not on an empty review. A reviewer reading a diff cannot tell a
deliberate, documented trade-off from an oversight, and each round tends to critique the code and comments
the previous round wrote - so re-running produces findings that were already considered. Treating those as
work to do is what turns the loop into a treadmill.

The summary line reports this directly. `new=N/M` means N of the M findings were not in the previous
review; `new=0` means every one of them was already raised:

```
preflight: issues=2 security=No risk=low merge=review carefully effort=3 tokens=71791 new=0/2 (unchanged since the previous review: judge each, do not re-fix blind)
```

- **`new=` above zero** - there is something the last round did not see. Fix those.
- **`new=0`** - stop and read, do not re-fix. For each finding decide which it is, and act accordingly:
  - *a real defect* - fix it (this happens, and is the whole reason the loop exists);
  - *already answered* - a limit, trade-off or alternative that the code, a comment or the docs already
    address. Do not "fix" it by churning the code. If the reasoning is not yet written down, write it
    down once - that is what stops the next round raising it - and do not rewrite the design to satisfy a
    preference;
  - *wrong* - say so and move on.
- **Two rounds with `new=0`** is the point to stop and hand off, whatever remains. Note in the pull
  request which findings you judged as answered and why, so a human sees the reasoning rather than the
  loop's history.

### How much to change: fix the defect, not the narrative

The stop condition above is necessary but not sufficient, because there is a second way to keep the loop
alive: **changing more than the finding requires, so the next round has more to review.** Code fixes are
usually small. The prose written *about* them is not, and a reviewer reads both.

The failure looks like this. A round reports one bug. You fix the code in ~10 lines, then also: rewrite the
surrounding comments to explain the fix, add a paragraph to the docs, add a changelog bullet, and add a
test-table row asserting the new test covers the fix. The next round reviews the *claims* you just made -
"this is guarded", "only these statuses are treated as non-failures" - and reports that some of them are
inaccurate. They often are, because prose written to describe a fix is not verified the way the fix is. You
correct the prose, which adds more prose, and the loop has no reason to stop. Measured on one real change:
about **56 lines of executable logic and 271 lines of comment** about it, over five rounds in which the
only findings still arriving were about the writing.

So, when applying a round's findings:

- **Change the code the finding requires and little else.** Do not rewrite comments, docs or the changelog
  unless the finding is *about* them.
- **Do not add a sentence describing a fix.** If the code is now correct, that is the record. A comment
  explaining what you just changed is the most reviewable text in the diff and the least useful: it
  duplicates the diff, and it can only be checked by reading the diff.
- **Never write an unverified claim about coverage.** "This is guarded by test X" and "every mutation is
  listed" are factual claims; a reviewer will check them, and if you did not run them yourself they are
  usually wrong in the direction of overclaiming. Either verify by mutation (see below) or do not write it.
- **Prefer deleting a claim to qualifying it.** When a finding says a comment overstates something, the fix
  is usually to remove the sentence, not to add a caveat to it. Sub-clauses about limits are exactly the
  surface the next round spends its budget on.
- **When `new=0`, default to no change at all.** "Write it down once" above means *only* if the reasoning is
  genuinely missing from the code and someone would re-raise it without it. It does not mean documenting
  the review.

A useful test before submitting: if a reviewer saw only your diff, would it have more *claims* to check
than *code* to check? If yes, cut until it does not.

### Verifying a claim cheaply, when you must make one

Claims about tests and guards are sometimes unavoidable - a requirement table, a coverage note. The rule is
that the claim is only true if you **ran** the failure it describes:

1. apply the mutation (break the guard);
2. run the suite;
3. confirm the specific case FAILS;
4. revert the mutation, and re-run to confirm it passes again.

A case that stays green with its guard removed is worth nothing, and its table row is a false assertion that
will be caught - possibly several rounds later, at full cost, after you have forgotten writing it. If you
cannot run the mutation, do not write the claim.

`new=` is a strong hint, not a verdict: it matches finding text (per pr-agent's own dedupe key), so a
lightly reworded repeat can still read as new. It is absent on a first review, and absent if the previous
review is unreadable. When it is absent, judge the findings yourself - and never re-fix a finding you have
already answered in this branch.

The review is configured to report **all** findings in one pass: it raises the finding cap, tells the
model to report everything it is confident about, and reviews an oversized diff in chunks (merging the
chunks' findings) instead of pruning files. Still, **read the coverage note**: if the summary line
contains `coverage=PARTIAL`, the token budget left files out of the review and `review.md` names them
(the full text is `coverage=PARTIAL (token budget left files out - see review.md)`). A low `issues=`
count on a partial review means "the rest was not looked at", not "the change is clean" - raise
`max_model_tokens`/`custom_model_max_tokens` (see the bundle's `docs/TROUBLESHOOTING.md`) rather than
round-tripping until the omitted files happen to come into view.

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
mkdir -p .githooks
install -m 0755 ~/.config/preflight/githooks/* .githooks/   # -m: git IGNORES a non-executable hook
git add .githooks
git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit
git commit -m "chore: enforce preflight before commits"
git config core.hooksPath .githooks              # RELATIVE - see the note below
```

Use `install -m`, not `cp`. `cp` preserves the source mode, so it usually works - but git **ignores a
hook file that is not executable**, printing a hint and running nothing, so if the mode is ever lost the
repo silently enforces nothing rather than failing. `git update-index --chmod=+x` then puts the mode in
the *index*, which is what a fresh clone obeys; `git add` alone records `100644` where git runs with
`core.fileMode=false`. Check both with `git ls-files -s .githooks/` - each line must read `100755`.

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
  exists, and a pre-commit hook runs before the commit it would cover). The default `commit` scope is
  enforceable.
- A second hook, `post-commit`, is **advisory** - it cannot block, since the commit already exists. It
  exists to break the silence when enforcement did not apply, and it reports two things: a review that
  used `head` scope (nothing you have committed since was verified), and a review sidecar it cannot read
  (a missing `python3`, or a malformed/`scope`-less `.preflight/review.meta.json`). Silence is reserved for
  "verified" and for "no review has run yet", so a warning here means *check*, not *panic*.
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
