## Review before the pull request (preflight)

Every change is reviewed before it becomes a pull request, and again after any change made in response to
that review. The reviewer is a machine-local PR-Agent run over the **working tree** - no GitHub round trip,
and no commit required:

```sh
preflight review   # the pending change (HEAD -> working tree) -> .preflight/review.md + .preflight/review.json
preflight-gate     # exit 0 = pass, 1 = changes required, key issues, or effort above the ceiling,
                   #          2 = security concerns, 3 = no review yet
```

`preflight --help` lists every command and environment variable; `preflight --version` reports the
installed bundle version.

### What to keep, and what to drop

**This block is meant to be adapted, not pasted whole.** An installed bundle does not need its own
installation instructions repeated in every repository that uses it, and every line that stays is a line
the next agent reads before it reaches the rules it has to follow. Keep the **required** material as it is
written - a paraphrase of a fact about the installed helper is a fact that drifts from it - and cut the
**setup** parts once they are done.

- **required** - the loop does not work correctly without it: what a review covers, what the gate decides
  on, how to read the stop signal, how to keep the round count down, and (if the repo enforces) what the
  hook does.
- **setup** - needed to install the bundle or adopt the hook, and worth nothing once that is done.

| Section | Class | What must survive, or when it can go |
|---|---|---|
| `## Review before the pull request (preflight)` | required | the loop, the commands and the gate's exit codes; the `--help`/`--version` line is optional |
| `### What to keep, and what to drop` | setup | you have read it |
| `### Scope` | required | what a review covers, and that a `head`-scope review cannot be enforced |
| `### Read the review` | required | `new=` and `coverage=` are the stop condition; the `review.json` field list is optional unless something parses that file |
| `### Optimising the review process` | required | every habit in it: they are what keep the round count - and the loop's whole cost - down |
| `### Operating invariants` | required | the install pointer at the end is setup; the rest is not |
| `### Make it enforced: refuse a commit that was not reviewed` | setup | `.githooks/` is committed - **but keep the per-clone `git config core.hooksPath .githooks` step somewhere**, since it is local config that a clone does not inherit, or no clone will enforce |
| `#### What the hook does, and does not do` | required | drop it only if the repository does not enforce: this is what makes a blocked commit explicable, and it is not derivable from the recipe above it |
| `### Tell the reviewer what is true about this repo` | required | it is what stops a documented trade-off being reported as a finding, which is a round the loop otherwise pays for |
| `### Where the bundle lives, and how to get current guidance` | setup | the upgrade recipe goes; **if the repository re-pastes after upgrades, keep the rule that the copy to paste is the installed one** (`$PREFLIGHT_HOME/AGENTS-review-snippet.md`, `~/.config/preflight` by default), not the repository's - plus a pointer to the repository |

### Scope

`preflight review` reviews **the pending commit**: everything HEAD does not yet contain, tracked and
untracked. Its diff comes from a throwaway snapshot of the working tree, so reviewing never stages,
commits or rewrites anything - the index is untouched and HEAD does not move. Reviewing commit by commit
covers a multi-commit branch completely, because each commit is checked against the tree that was reviewed
for it.

| `PREFLIGHT_SCOPE` | Covers | Enforceable by the hook |
|---|---|---|
| `commit` (default) | HEAD -> working tree, untracked included | yes |
| `worktree` | the whole branch vs the default branch; needs a resolvable base and a fetch | yes |
| `head` | committed content only (base...HEAD) | no |

`PREFLIGHT_BASE` overrides the base for `worktree`.

### Read the review

`preflight review` prints a summary line and writes its artifacts:

- `.preflight/review.md` - prose.
- `.preflight/review.json` - structured: `review.key_issues_to_review[]`, `review.security_concerns`,
  `review.relevant_tests`, `review.estimated_effort_to_review_[1-5]`, `review.risk_level`,
  `review.merge_recommendation`.

Loop until `preflight-gate` exits 0: fix every entry in `key_issues_to_review[]` and anything under
`security_concerns` in one pass, then re-run `preflight review` and `preflight-gate`.

What matters on the summary line is the loop's exit conditions:

- `new=N/M` - N of the M findings were not in the previous review. `new=0` means every finding was already
  raised: judge each one rather than re-fixing blind.
- `coverage=PARTIAL (token budget left files out - see review.md)` - the token budget left files out of the
  review, so a low `issues=` count means "the rest was not looked at", not "the change is clean". Inform
  that `config.max_model_tokens` / `custom_model_max_tokens` can be raised (see
  `docs/runbooks/troubleshooting.md`) rather than round-tripping until the omitted files happen to come into view.
- `model=FALLBACK (the configured model did not answer - see review.md)` - the review you are reading came
  from the fallback model, not the configured one. Treat a clean result with more caution than usual: it is
  a different model's judgement, and the run may be much slower and more expensive than the same review
  normally is. Raise `config.max_output_tokens` if you see it on an install that does not set it - see
  `docs/runbooks/troubleshooting.md` rather than re-running.

`risk=` is reported but the gate never decides on it; the gate fails on security concerns,
key issues, effort above `PREFLIGHT_GATE_MAX_EFFORT`, or - when the repository asks for it with
`require_merge_recommendation` - `merge_recommendation=changes_required`.

### Optimising the review process

Every round is a full model call that re-reads the whole diff, so these habits are what keep the loop short:

- **Fix everything material in one pass.** A round that resolves many findings is cheaper than many rounds
  that resolve one each.
- **A review reports on prose as hard as on code.** A claim the reviewer can check and you have not is a
  finding you bought. Write less commentary, and make sure what you write is true.
- **Do not document behaviour you have not settled.** Write the code, confirm what it does, then describe
  it - a rationale written ahead of its behaviour tends to contradict it, and the next review reports the
  paragraph.
- **A number in prose is a copy nothing checks.** The run, the code and the artifact already own the fact,
  so the copy in your prose goes stale in silence - and a review reports prose as hard as code, so it comes
  back as a finding. State the shape ("every section passed") or quote the run's output in a code fence;
  this covers a count of the list you just wrote as much as a run result. A number that *is* the interface
  (a timeout, an exit code, a port) stays.

### Operating invariants

- **Do not commit to be reviewed.** The loop runs in the working tree; commit once, for the pull request.
- **The review supplements your test/lint gate, it does not replace it.** A clean review says nothing about
  types, lint or the tests.
- **`.preflight/` is gitignored and per worktree.** The exclude lives in `.git/info/exclude`, so review
  output is never committed and two worktrees never collide. `preflight` adds the exclude itself, and for
  the branch scopes it fetches the remote before diffing, so it never compares against a stale local
  default branch.
- **The helpers are machine-local, not part of the repository.** They live in `~/.local/bin` and are driven
  by `~/.config/preflight/preflight.toml`, and work against any OpenAI-compatible endpoint. If they are
  missing, install them with the bundle's `install.sh`. Other commands: `preflight describe`,
  `preflight improve`, `preflight ask "<question>"`.

### Make it enforced: refuse a commit that was not reviewed

To make the repo **refuse** an unreviewed commit, commit a pre-commit hook and point git at it. The hook
files are committed; `core.hooksPath` is **local config, not a committed file**, so a fresh clone does
**not** inherit it and enforces nothing until it is set again there:

```sh
mkdir -p .githooks
install -m 0755 ~/.config/preflight/githooks/* .githooks/   # -m: git IGNORES a non-executable hook
git add .githooks
git update-index --chmod=+x .githooks/pre-commit .githooks/post-commit
git commit -m "chore: enforce preflight before commits"
git config core.hooksPath .githooks              # RELATIVE - an absolute path breaks git worktrees
```

Use `install -m`, not `cp`: git ignores a hook file that is not executable, so a lost mode silently
enforces nothing. `git update-index --chmod=+x` puts the mode in the *index*, which is what a fresh clone
obeys. Check both with `git ls-files -s .githooks/` - each line must read `100755`.

#### What the hook does, and does not do

- It **verifies** that the content being committed was what `preflight review` reviewed. Unreviewed content
  blocks the commit, and the offending paths are named. The recorded review must also have **passed**
  `preflight-gate`.
- It **never runs a review** and never stages anything; it only reads.
- It is **content-based, not time-based**: there is no expiry. A review counts while the content it covered
  is what is being committed.
- The rule is **containment, not equality**: every path being committed must match the reviewed tree, and
  reviewed content that is *not* being committed is ignored - which is what keeps `git commit -a` and
  newly staged files working.
- A deletion, a rename (`git mv`) or a symlink/file-type swap is blocked until a review covers it: a
  deletion removes reviewed content the review vouched for, and a rename or type swap leaves the path
  present but no longer doing what the review saw.
- The **first** commit in a repository with no history is allowed but not enforced.
- `head` scope reviews cannot be enforced; the default `commit` scope and `worktree` can.
- `post-commit` is **advisory** - it cannot block. It warns when the last review used `head` scope, or when
  the sidecar `.preflight/review.meta.json` cannot be read or lacks a `scope`. Silence means "verified" or
  "no review yet" (before the first commit there is nothing to read).
- `PREFLIGHT_SKIP=1` (or `git commit --no-verify`) bypasses the check once.
- The verifier is `$PREFLIGHT_HOOK`, defaulting to `~/.config/preflight/preflight-hook`. If that helper is
  missing the commit is **refused**, not passed - re-run the bundle's `install.sh`, or point
  `PREFLIGHT_HOOK` at a vendored copy.

`.preflight/` is left in place on a block, so `.preflight/review.md` has the detail; the verdict is also
recorded in `.preflight/review.meta.json`.

### Tell the reviewer what is true about this repo

A reviewer cannot tell a deliberate, documented trade-off from an oversight, so it reports the trade-off as
a finding. Give it the facts in `AGENTS.md`, in a heading whose text starts with `Code review` - a
`#`-style heading, not an underlined (Setext) one - and that section, and only that section, is sent with
the review:

```markdown
## Code review

- `src/legacy/` is vendored; do not suggest refactors there.
- The `+1` offset in `parser.py` is required by the wire format, not an off-by-one.
- Writes to `.cache/` are intentionally not atomic; a crash there is recoverable by design.
```

With no such heading the whole file is sent, so an existing `AGENTS.md` is used as-is. The summary line
reports `context=<file> (Code review section)` when the section was used. Record **facts, not verdicts**:
what is *true* about the repository, never "do not report X" - if a category of finding should not block,
that is what the gate's tier and opt-outs are for. Keep it current, because a stale entry actively
misleads. The file is read from the working tree, so a change to it is part of the next review.

### Where the bundle lives, and how to get current guidance

The helpers, the config template and the full docs live in the bundle's own repository:

**<https://github.com/413x5/preflight>**

Read it (do not guess) when this snippet does not answer a question about `preflight`:

- `README.md` - install, use, and the "using another provider" recipe.
- `docs/architecture.md` - how the working-tree snapshot, the commit hook, the gate and the provider config work.
- `docs/runbooks/troubleshooting.md` - symptoms and fixes.

**Re-paste this snippet from your local installation**, not from the repository. The installed copy at
`~/.config/preflight/AGENTS-review-snippet.md` is the one that matches the `preflight` actually on this
machine, so every command and env var it names is one the installed bundle understands - a newer snippet
pasted over an older helper would describe behaviour that is not there:

```sh
cat ~/.config/preflight/AGENTS-review-snippet.md    # copy this into AGENTS.md
```

To check whether the bundle itself is current, compare the installed version with the repository's. If the
repository is ahead, re-run its `install.sh` first and re-paste afterwards, so the snippet and the helpers
move together:

```sh
preflight --version                                                            # installed
gh api -H 'Accept: application/vnd.github.raw' repos/413x5/preflight/contents/src/VERSION
```
